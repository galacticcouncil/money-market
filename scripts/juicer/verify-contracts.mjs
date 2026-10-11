// verify deployed contracts on the neckwork explorer (sourcify v2 api) against the exact
// production build. a dry run by default; --live submits and polls, --check only probes.
//
//   node scripts/juicer/verify-contracts.mjs [records...] [--live | --check]
//     records  forge broadcast run files or directories (default juicer-vault/broadcast),
//              lark journals, or hardhat-deploy records (they carry their own solc input)
//     --out    build output with build-info, repeatable (default juicer-vault/out-production)
//     --api    verifier base (NECKWORK_API, default neckwork)  --chain  (default 222222)
//     --rpc    (RPC) reads constructor-created helpers a record does not name
//     --state  in-flight jobs, for resuming (default in the temp dir)  --dump DIR  request bodies
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {existsSync,mkdirSync,readFileSync,readdirSync,statSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {basename,dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {utils} from 'ethers';

const ROOT=fileURLToPath(new URL('../../',import.meta.url));
export const NECKWORK='https://hydration-explorer.neckwork.net/api';
// the verifier compiles every accepted submission; probes and polls are not limited
export const LIMITS={submits:10,windowMs:60_000,pollMs:3_000,pollTimeoutMs:300_000,retries:5};
// helpers created in constructors, and the getters that name them
const HELPERS={CollateralVault:[['compoundLogic()','CompoundLogic']],JuicerMainDebt:[['yieldAccounting()','JuicerYieldAccounting']]};
const OUTPUTS={'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object','metadata']}};

const readJson=file=>JSON.parse(readFileSync(file,'utf8'));
const hex=s=>(s??'').replace(/^0x/,'').toLowerCase();
const keccak=s=>utils.keccak256(utils.toUtf8Bytes(s));
const same=(a,b)=>!!a&&!!b&&a.toLowerCase()===b.toLowerCase();

export function loadBuilds(dirs){
 const found=[];
 for(const dir of dirs){
  const info=join(dir,'build-info');
  assert.ok(existsSync(info),`${info} is missing: rebuild with --build-info`);
  for(const file of readdirSync(info).filter(f=>f.endsWith('.json')).sort()){
   const build=readJson(join(info,file));
   for(const [path,contracts] of Object.entries(build.output?.contracts??{}))
    for(const [name,c] of Object.entries(contracts))if(c.evm?.bytecode?.object)found.push({build,path,name,c});
  }
 }
 return found;
}

// forge's input lacks the out-of-root libraries solc read from disk, so send the
// contract's metadata closure, each source checked against its metadata hash
export function requestBody({build,path,name,c}){
 const meta=JSON.parse(c.metadata),{sources,settings,basePath}=build.input,closure={};
 for(const [unit,{keccak256}] of Object.entries(meta.sources)){
  const source=sources[unit]??(basePath?sources[resolve(basePath,unit)]:undefined);
  assert.ok(typeof source?.content==='string',`${path}:${name}: build-info ${build.id} lacks ${unit}`);
  assert.equal(keccak(source.content),keccak256,`${path}:${name}: ${unit} is not the compiled source`);
  closure[unit]={content:source.content};
 }
 return {
  // outputSelection named the original files; it never changes bytecode
  stdJsonInput:{language:build.input.language??'Solidity',sources:closure,settings:{...settings,outputSelection:OUTPUTS}},
  // forge writes solcLongVersion without the commit the verifier fetches solc by
  compilerVersion:/\+commit\./.test(build.solcLongVersion??'')?build.solcLongVersion:meta.compiler.version,
  contractIdentifier:`${path}:${name}`,
 };
}

// the ipfs hash inside each embedded metadata block
const CBOR=/a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033/g;
const unhashed=s=>s.replace(CBOR,m=>m.slice(0,16)+'0'.repeat(68)+m.slice(84));
// compiled init code against a deployment's: exact, metadata hash only, or different code
export function compareInit(compiled,init){
 const code=hex(compiled),sent=hex(init).slice(0,code.length);
 if(!code||sent.length<code.length)return 'mismatch';
 return code===sent?'exact':unhashed(code)===unhashed(sent)?'partial':'mismatch';
}

function fromBroadcast(j,file){
 const receipts=new Map((j.receipts??[]).map(r=>[r.transactionHash?.toLowerCase(),r]));
 const rows=[];
 for(const t of j.transactions){
  if(!['CREATE','CREATE2'].includes(t.transactionType)||!t.contractAddress)continue;
  const receipt=receipts.get(t.hash?.toLowerCase()),input=hex(t.transaction?.input??t.transaction?.data);
  // a CREATE2 factory call puts the salt before the init code
  const row={name:t.contractName||null,address:t.contractAddress,tx:t.hash,file,init:t.transactionType==='CREATE2'?input.slice(64):input};
  if(!receipt)row.skip='no receipt in broadcast';
  else if(Number(receipt.status)!==1)Object.assign(row,{skip:'reverted',reverted:true});
  if('additionalContracts' in t)row.helpers=t.additionalContracts.map(a=>({name:a.contractName||null,address:a.address,init:hex(a.initCode)}));
  rows.push(row);
 }
 return rows;
}

function fromJournal(j,file){
 const sent=new Map((j.calls??[]).map(c=>[c.label,c.hash])),a=j.addresses??{};
 return j.deployments.map(d=>{
  const row={name:d.name,label:d.label,address:d.address,tx:sent.get(`deploy.${d.label}`)??null,file};
  // lark journals record the constructor-created helpers beside their parents
  const vault=(j.vaults??[]).find(v=>same(v.mainDebt,d.address));
  if(d.name==='CollateralVault'&&same(a.vaultImpl,d.address)&&a.compoundLogic)row.helpers=[{name:'CompoundLogic',address:a.compoundLogic}];
  if(d.name==='JuicerMainDebt'&&vault?.yieldAccounting)row.helpers=[{name:'JuicerYieldAccounting',address:vault.yieldAccounting}];
  return row;
 });
}

// hardhat-deploy records keep the exact solc input beside them in solcInputs/
function fromHardhat(j,file){
 const meta=JSON.parse(j.metadata),[[path,name]]=Object.entries(meta.settings.compilationTarget);
 const input=readJson(join(dirname(file),'solcInputs',`${j.solcInputHash}.json`));
 for(const [unit,{keccak256}] of Object.entries(meta.sources))
  assert.equal(keccak(input.sources[unit]?.content??''),keccak256,`${file}: ${unit} is not the compiled source`);
 return [{name,label:basename(file,'.json'),address:j.address,tx:j.transactionHash??null,file,status:'recorded',
  body:{stdJsonInput:input,compilerVersion:meta.compiler.version,contractIdentifier:`${path}:${name}`,...(j.transactionHash?{creationTransactionHash:j.transactionHash}:{})}}];
}

// forge keeps each run as run-<timestamp>.json beside run-latest.json; dry runs deployed nothing
function runFiles(dir,chain){
 return readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?e.name==='dry-run'?[]:runFiles(join(dir,e.name),chain)
  :/^run-.*\.json$/.test(e.name)&&basename(dir)===chain?[join(dir,e.name)]:[]);
}

export function loadRecords(paths,chain='222222'){
 const docs=[];
 for(const p of paths){
  assert.ok(existsSync(p),`${p}: no deployment records; pass forge broadcast run files`);
  if(!statSync(p).isDirectory()){docs.push({file:p,j:readJson(p)});continue;}
  docs.push(...runFiles(p,String(chain)).map(file=>({file,j:readJson(file)})).sort((a,b)=>(a.j.timestamp??0)-(b.j.timestamp??0)));
 }
 return docs.flatMap(({file,j})=>{
  if(Array.isArray(j.transactions))return fromBroadcast(j,file);
  if(Array.isArray(j.deployments))return fromJournal(j,file);
  if(j.solcInputHash&&j.metadata)return fromHardhat(j,file);
  throw Error(`${file}: not a forge broadcast, Lark journal or hardhat-deploy record`);
 });
}

async function ethCall(fetch,rpc,to,signature){
 const res=await fetch(rpc,{method:'POST',headers:{'content-type':'application/json'},
  body:JSON.stringify({jsonrpc:'2.0',id:1,method:'eth_call',params:[{to,data:utils.id(signature).slice(0,10)},'latest']})});
 const {result}=await res.json();
 assert.match(result??'',/^0x[0-9a-f]{64}$/i,`${signature} on ${to} failed`);
 return utils.getAddress('0x'+result.slice(26));
}

// neckwork reads a CREATE transaction as creating only its receipt's address, so a helper
// created in a constructor goes without one and is matched on its runtime code alone
export async function withHelpers(rows,{rpc,fetch}){
 const out=[];
 for(const row of rows){
  out.push(row);
  let helpers=row.helpers;
  if(!helpers?.length&&HELPERS[row.name]&&!row.skip){
   assert.ok(rpc,`${row.name} ${row.address}: helpers not recorded; pass --rpc to read ${HELPERS[row.name].map(([g])=>g).join(', ')}`);
   helpers=[];
   for(const [getter,name] of HELPERS[row.name])helpers.push({name,address:await ethCall(fetch,rpc,row.address,getter)});
  }
  for(const h of helpers??[])out.push({...h,parent:row.label??row.name,file:row.file,...(row.skip?{skip:row.skip,reverted:row.reverted}:{})});
 }
 // the same deployment in several runs or records: keep a confirmed one
 const byAddress=new Map();
 for(const row of out){const k=row.address.toLowerCase(),seen=byAddress.get(k);if(!seen||(seen.skip&&!row.skip))byAddress.set(k,row);}
 return [...byAddress.values()];
}

export function resolveTargets(rows,contracts){
 return rows.map(row=>{
  if(row.body||row.skip)return row;
  const named=contracts.filter(x=>!row.name||x.name===row.name);
  let hit,status;
  if(row.init){
   for(const x of named){
    const s=compareInit(x.c.evm.bytecode.object,row.init);
    if(s==='exact'){hit=x;status=s;break;}
    if(s==='partial'&&!hit){hit=x;status=s;}
   }
   status??=row.name&&!named.length?'no build':'mismatch';
  }else{
   // nothing deployed to compare: the name must select one compiled bytecode
   const codes=new Set(named.map(x=>x.c.evm.bytecode.object));
   if(row.name&&codes.size===1){hit=named[0];status='unchecked';}
   else status=named.length?'ambiguous':'no build';
  }
  if(!hit)return {...row,status};
  const body=requestBody(hit);
  if(row.tx)body.creationTransactionHash=row.tx;
  return {...row,name:hit.name,status,build:hit.build.id,body};
 });
}

const label=t=>(t.label??t.name??'?')+(t.parent?` (in ${t.parent})`:'');

function table(rows,log){
 const head=['contract','address','build','result'];
 const cells=rows.map(t=>[label(t),t.address,t.status??'-',t.result??'-']);
 const w=head.map((h,i)=>Math.max(h.length,...cells.map(c=>c[i].length)));
 for(const c of [head,...cells])log(c.map((x,i)=>i<3?x.padEnd(w[i]):x).join('  '));
}

function describe(t,api,chain,log){
 const b=t.body,s=b.stdJsonInput.settings,size=JSON.stringify(b).length;
 log(`${label(t)} ${t.address}: ${t.status}${t.build?` against build-info ${t.build}`:''}`);
 log(`  POST ${api}/v2/verify/${chain}/${t.address}`);
 log(`  contractIdentifier ${b.contractIdentifier}`);
 log(`  compilerVersion ${b.compilerVersion}`);
 const n=Object.keys(b.stdJsonInput.sources).length;
 log(`  stdJsonInput ${n} source${n===1?'':'s'}, ${s.evmVersion??'default evm'}, viaIR ${!!s.viaIR}, optimizer ${s.optimizer?.enabled?`${s.optimizer.runs} runs`:'off'}; ${Math.ceil(size/1024)} KiB, sha256 ${createHash('sha256').update(JSON.stringify(b)).digest('hex').slice(0,16)}`);
 log(`  creationTransactionHash ${b.creationTransactionHash??(t.parent?'none: constructor-created, runtime match':'none')}`);
}

export async function main(argv=process.argv.slice(2),io={}){
 const {fetch=globalThis.fetch,sleep=ms=>new Promise(r=>setTimeout(r,ms)),now=Date.now,log=console.log}=io;
 const {values:o,positionals}=parseArgs({args:argv,allowPositionals:true,options:{
  live:{type:'boolean'},check:{type:'boolean'},out:{type:'string',multiple:true},api:{type:'string'},
  chain:{type:'string'},rpc:{type:'string'},state:{type:'string'},dump:{type:'string'}}});
 assert.ok(!(o.live&&o.check),'--live and --check exclude each other');
 const chain=o.chain??'222222',api=(o.api??process.env.NECKWORK_API??NECKWORK).replace(/\/+$/,'');
 let rows=await withHelpers(loadRecords(positionals.length?positionals:[join(ROOT,'juicer-vault/broadcast')],chain),{rpc:o.rpc??process.env.RPC,fetch});
 assert.ok(rows.length,'no deployments in the records');
 if(!o.check&&rows.some(t=>!t.body&&!t.skip))rows=resolveTargets(rows,loadBuilds(o.out??[join(ROOT,'juicer-vault/out-production')]));
 if(o.dump){
  mkdirSync(o.dump,{recursive:true});
  for(const t of rows)if(t.body)writeFileSync(join(o.dump,`${t.name}-${t.address}.json`),JSON.stringify(t.body,null,1)+'\n');
 }
 const absolute=new Set(rows.flatMap(t=>(t.body?.stdJsonInput.settings.remappings??[]).filter(r=>/=\//.test(r))));
 if(!o.check&&absolute.size)log(`note: ${absolute.size} remapping(s) name absolute build paths; neckwork publishes them, and only a build at the same path matches the metadata hash exactly`);
 if(!o.live&&!o.check){
  log('dry run: nothing submitted (--live submits, --check probes)');
  for(const t of rows)if(t.body)describe(t,api,chain,log);
  for(const t of rows)t.result=t.body?'would submit':t.skip??`not submitted: ${t.status}`;
  table(rows,log);
  return rows.every(t=>t.body||t.reverted)?0:1;
 }

 const statePath=o.state??join(tmpdir(),`juicer-verify-${chain}.json`);
 const state=existsSync(statePath)?readJson(statePath):{};
 const save=()=>writeFileSync(statePath,JSON.stringify(state,null,1)+'\n');
 async function http(method,path,body){
  const res=await fetch(api+path,{method,headers:{accept:'application/json',...(body?{'content-type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const text=await res.text();let json=null;
  try{json=JSON.parse(text);}catch{}
  return {status:res.status,json,retryAfter:Number(res.headers.get('retry-after'))||null};
 }
 const sent=[];
 async function submit(t){
  for(let attempt=0;;attempt++){
   for(;;){
    while(sent.length&&now()-sent[0]>=LIMITS.windowMs)sent.shift();
    if(sent.length<LIMITS.submits)break;
    await sleep(sent[0]+LIMITS.windowMs-now());
   }
   sent.push(now());
   const r=await http('POST',`/v2/verify/${chain}/${t.address}`,t.body);
   if(r.status!==429||attempt>=LIMITS.retries)return r;
   await sleep((r.retryAfter??60)*1000);
  }
 }
 // the job, null for an id neckwork does not know, or {pending} past the timeout
 async function poll(id){
  for(const until=now()+LIMITS.pollTimeoutMs;;){
   const r=await http('GET',`/v2/verify/${encodeURIComponent(id)}`);
   if(r.status===404)return null;
   assert.equal(r.status,200,`job ${id}: HTTP ${r.status}`);
   if(r.json.isJobCompleted)return r.json;
   if(now()>=until)return {pending:true};
   await sleep(LIMITS.pollMs);
  }
 }
 async function settle(t){
  if(t.reverted)return {ok:true,result:'reverted, nothing deployed'};
  const key=t.address.toLowerCase();
  const probe=await http('GET',`/v2/contract/${chain}/${t.address}`);
  if(probe.status===200&&probe.json?.match){if(state[key]){delete state[key];save();}return {ok:true,result:`verified ${probe.json.match}`};}
  assert.equal(probe.status,404,`probe ${t.address}: HTTP ${probe.status}`);
  if(o.check)return {ok:false,result:'unverified'};
  if(!t.body)return {ok:false,result:t.skip??`not submitted: ${t.status}`};
  let id=state[key],job=id?await poll(id):null;
  if(!job){
   const r=await submit(t);
   if(r.status===409)return {ok:true,result:'verified (already)'};
   if(r.status!==202)return {ok:false,result:`rejected ${r.json?.customCode??`HTTP ${r.status}`}: ${r.json?.message??''}`.trim()};
   id=state[key]=r.json.verificationId;save();
   job=await poll(id);
   assert.ok(job,`job ${id} vanished`);
  }
  if(job.pending)return {ok:false,result:`pending ${id}; rerun to resume`};
  delete state[key];save();
  const c=job.contract??{};
  if(c.match)return {ok:true,result:c.match+(c.creationMatch?`, creation ${c.creationMatch}`:'')};
  return {ok:false,result:`failed ${job.error?.customCode??'no_match'}: ${job.error?.message??''}`.trim()};
 }
 let failed=0;
 for(const t of rows){
  const {ok,result}=await settle(t);
  t.result=result;failed+=!ok;
  if(o.live)log(`${label(t)} ${t.address}: ${result}`);
 }
 table(rows,log);
 return failed?1:0;
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))
 main().then(code=>{process.exitCode=code;},e=>{console.error(e.message);process.exitCode=1;});
