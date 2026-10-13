import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {cpSync,mkdirSync,mkdtempSync,readFileSync,readdirSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {LIMITS,compareInit,main} from './verify-contracts.mjs';

const here=fileURLToPath(new URL('.',import.meta.url)),fx=join(here,'fixtures/verify');
const OUT=join(fx,'production'),RUNS=join(fx,'runs'),RUN=join(RUNS,'DeployMain.s.sol/222222/run-1791000000.json');
const read=file=>JSON.parse(readFileSync(file,'utf8'));
const MAIN=read(join(OUT,'build-info/5f3a9c1e2b7d4a60.json')),PROXY=read(join(OUT,'build-info/c04e7b19d2a8f356.json'));
const TX=read(RUN).transactions.map(t=>t.hash);
const A={synth:'0x1000000000000000000000000000000000000001',vault:'0x1000000000000000000000000000000000000002',logic:'0x1000000000000000000000000000000000000003',proxy:'0x1000000000000000000000000000000000000004'};
const API='https://verifier.test/api';
const dirs=[];
after(()=>{for(const dir of dirs)rmSync(dir,{recursive:true,force:true});});
const temp=()=>{const dir=mkdtempSync(join(tmpdir(),'verify-contracts-'));dirs.push(dir);return dir;};

// the exact request bodies: each contract's metadata closure, never forge's whole input
const SETTINGS={remappings:['@base/=../bil-vault/lib/base/src/','base/=/build/money-market/bil-vault/lib/base/src/'],optimizer:{enabled:true,runs:200},
 metadata:{useLiteralContent:false,bytecodeHash:'ipfs',appendCBOR:true},outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object','metadata']}},
 evmVersion:'london',viaIR:true,libraries:{}};
const content=(build,unit)=>({content:build.input.sources[unit].content});
const PROXY_SOL='../bil-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol';
const BODIES={
 [A.synth]:{stdJsonInput:{language:'Solidity',settings:SETTINGS,sources:{'src/SyntheticToken.sol':content(MAIN,'src/SyntheticToken.sol'),
  // root-relative in the metadata, absolute in forge's input
  '../bil-vault/lib/base/src/Base.sol':content(MAIN,'/build/money-market/bil-vault/lib/base/src/Base.sol')}},
  compilerVersion:'0.8.22+commit.4fc1097e',contractIdentifier:'src/SyntheticToken.sol:SyntheticToken',creationTransactionHash:TX[0]},
 [A.vault]:{stdJsonInput:{language:'Solidity',settings:SETTINGS,sources:{'src/CollateralVault.sol':content(MAIN,'src/CollateralVault.sol'),'src/lib/CompoundLogic.sol':content(MAIN,'src/lib/CompoundLogic.sol')}},
  compilerVersion:'0.8.22+commit.4fc1097e',contractIdentifier:'src/CollateralVault.sol:CollateralVault',creationTransactionHash:TX[1]},
 // created by the vault constructor, so it has no creation transaction of its own
 [A.logic]:{stdJsonInput:{language:'Solidity',settings:SETTINGS,sources:{'src/lib/CompoundLogic.sol':content(MAIN,'src/lib/CompoundLogic.sol')}},
  compilerVersion:'0.8.22+commit.4fc1097e',contractIdentifier:'src/lib/CompoundLogic.sol:CompoundLogic'},
 [A.proxy]:{stdJsonInput:{language:'Solidity',settings:SETTINGS,sources:{[PROXY_SOL]:content(PROXY,PROXY_SOL),
  '../bil-vault/lib/oz/contracts/proxy/Proxy.sol':content(PROXY,'/build/money-market/bil-vault/lib/oz/contracts/proxy/Proxy.sol')}},
  compilerVersion:'0.8.22+commit.4fc1097e',contractIdentifier:`${PROXY_SOL}:ERC1967Proxy`,creationTransactionHash:TX[2]},
};

// a fake clock: sleeping advances it
function clock(){const c={t:0,now:()=>c.t,sleep:async ms=>{c.t+=ms;}};return c;}
// neckwork's three sourcify routes; jobs maps an id to the states its polls return in turn
function neckwork({verified=[],jobs={},submit,rpc,c=clock()}={}){
 const calls=[];let n=0;
 const reply=(status,body,headers)=>new Response(JSON.stringify(body),{status,headers});
 const fetch=async(url,init={})=>{
  const method=init.method??'GET',body=init.body?JSON.parse(init.body):undefined;
  calls.push({method,url,body,t:c.t});
  if(!url.startsWith(API))return rpc(body);
  const path=url.slice(API.length);let m;
  if(method==='GET'&&(m=path.match(/^\/v2\/contract\/222222\/(0x\w{40})$/)))
   return verified.includes(m[1])?reply(200,{match:'exact_match',creationMatch:'exact_match',runtimeMatch:'exact_match',chainId:'222222',address:m[1]})
    :reply(404,{match:null,creationMatch:null,runtimeMatch:null,chainId:'222222',address:m[1]});
  if(method==='POST'&&(m=path.match(/^\/v2\/verify\/222222\/(0x\w{40})$/)))return reply(...(submit?.(m[1],body)??[202,{verificationId:`job-${++n}`}]));
  if(method==='GET'&&(m=path.match(/^\/v2\/verify\/(.+)$/))){
   const states=jobs[m[1]]??(m[1].startsWith('job-')&&Number(m[1].slice(4))<=n?[{match:'exact_match'}]:null);
   if(!states)return reply(404,{customCode:'job_not_found',message:`No verification job found for id ${m[1]}`,errorId:'e'});
   const s=states.length>1?states.shift():states[0];
   if(s==='pending')return reply(200,{isJobCompleted:false,verificationId:m[1],jobStartTime:'2026-10-12T00:00:00.000Z',contract:{match:null,creationMatch:null,runtimeMatch:null,chainId:'222222',address:'0x'}});
   return reply(200,{isJobCompleted:true,verificationId:m[1],jobStartTime:'2026-10-12T00:00:00.000Z',jobFinishTime:'2026-10-12T00:00:09.000Z',
    contract:{match:s.match??null,creationMatch:s.creationMatch??null,runtimeMatch:s.match??null,chainId:'222222',address:'0x'},
    ...(s.error?{error:{customCode:s.error,message:'No contract could be verified with provided data',errorId:'e'}}:{})});
  }
  throw Error(`unexpected ${method} ${url}`);
 };
 return {fetch,calls,c,posts:()=>calls.filter(x=>x.method==='POST'&&x.url.startsWith(API))};
}
async function run(args,api,extra={}){
 const lines=[],state=extra.state??join(temp(),'state.json');
 const code=await main([...args,`--api=${API}`,`--state=${state}`],{fetch:api.fetch,sleep:api.c.sleep,now:api.c.now,log:l=>lines.push(l)});
 return {code,lines,state,row:name=>lines.findLast(l=>l.startsWith(name+' '))};
}
// a broadcast copy to edit
function runsWith(edit){
 const dir=temp(),file=join(dir,'DeployMain.s.sol/222222/run-1791000000.json');
 mkdirSync(join(dir,'DeployMain.s.sol/222222'),{recursive:true});
 const j=read(RUN);edit(j);writeFileSync(file,JSON.stringify(j));
 return dir;
}

test('the dry run is the default: it prints the requests and submits nothing', async () => {
 const dump=temp(),lines=[];
 const code=await main([RUNS,`--out=${OUT}`,`--dump=${dump}`,`--api=${API}`],{fetch:()=>assert.fail('a dry run fetched'),log:l=>lines.push(l)});
 assert.equal(code,0);
 assert.ok(lines.includes('dry run: nothing submitted (--live submits, --check probes)'));
 assert.ok(lines.includes(`  POST ${API}/v2/verify/222222/${A.vault}`));
 assert.match(lines[0],/^note: 1 remapping\(s\) name absolute build paths/);
 assert.equal(readdirSync(dump).length,4);
 for(const [address,body] of Object.entries(BODIES))
  assert.deepEqual(read(join(dump,`${body.contractIdentifier.split(':').at(-1)}-${address}.json`)),body);
 assert.match(lines.findLast(l=>l.startsWith('CompoundLogic (in CollateralVault) ')),/exact\s+would submit$/);
 assert.match(lines.findLast(l=>l.startsWith('ERC1967Proxy ')),/exact\s+would submit$/);
});

test('a live run skips verified contracts, submits the exact bodies and polls each job to completion', async () => {
 const api=neckwork({verified:[A.synth],jobs:{
  'job-1':['pending','pending',{match:'exact_match',creationMatch:'exact_match'}],
  'job-2':[{match:'exact_match'}],
  'job-3':[{match:'match',creationMatch:'exact_match'}]}});
 const r=await run([RUNS,`--out=${OUT}`,'--live'],api);
 assert.equal(r.code,0);
 assert.deepEqual(api.posts().map(p=>p.url),[A.vault,A.logic,A.proxy].map(a=>`${API}/v2/verify/222222/${a}`));
 for(const p of api.posts())assert.deepEqual(p.body,BODIES[p.url.slice(-42)]);
 assert.equal(api.calls.filter(x=>x.url===`${API}/v2/verify/job-1`).length,3);
 assert.equal(api.c.t,2*LIMITS.pollMs);
 assert.match(r.row('SyntheticToken'),/verified exact_match$/);
 assert.match(r.row('CollateralVault'),/exact\s+exact_match, creation exact_match$/);
 assert.match(r.row('CompoundLogic (in CollateralVault)'),/exact\s+exact_match$/);
 assert.match(r.row('ERC1967Proxy'),/match, creation exact_match$/);
 assert.deepEqual(read(r.state),{});
});

test('failed and rejected submissions fail the run', async () => {
 const api=neckwork({jobs:{'job-1':[{error:'no_match'}]},
  submit:a=>a===A.logic?[404,{customCode:'cannot_fetch_bytecode',message:`No contract code found at ${a}`,errorId:'e'}]
   :a===A.proxy?[409,{customCode:'already_verified',message:'Contract is already verified',errorId:'e'}]:undefined});
 const r=await run([RUNS,`--out=${OUT}`,'--live'],api);
 assert.equal(r.code,1);
 assert.match(r.row('SyntheticToken'),/failed no_match: No contract could be verified/);
 assert.match(r.row('CompoundLogic (in CollateralVault)'),/rejected cannot_fetch_bytecode: No contract code found/);
 assert.match(r.row('ERC1967Proxy'),/verified \(already\)$/);
});

test('constructor-created helpers come from the getters when a record does not name them', async () => {
 const runs=runsWith(j=>{for(const t of j.transactions)delete t.additionalContracts;});
 await assert.rejects(main([runs,`--out=${OUT}`],{log:()=>{}}),/helpers not recorded; pass --rpc to read compoundLogic\(\)/);
 const rpc=body=>{
  assert.deepEqual(body.params,[{to:A.vault,data:'0x11089f44'},'latest']);
  return new Response(JSON.stringify({jsonrpc:'2.0',id:1,result:'0x'+A.logic.slice(2).padStart(64,'0')}));
 };
 const dump=temp(),api=neckwork({rpc});
 const r=await run([runs,`--out=${OUT}`,'--rpc=http://rpc.test',`--dump=${dump}`],api);
 assert.equal(r.code,0);
 assert.match(r.row('CompoundLogic (in CollateralVault)'),/unchecked\s+would submit$/);
 assert.deepEqual(read(join(dump,`CompoundLogic-${A.logic}.json`)),BODIES[A.logic]);
});

test('submissions stay within ten a minute, and a 429 waits for its retry-after', async () => {
 const at=i=>'0x30000000000000000000000000000000000000'+i.toString(16).padStart(2,'0');
 const runs=runsWith(j=>{
  const [synth]=j.transactions,[receipt]=j.receipts;
  j.transactions=Array.from({length:12},(_,i)=>({...synth,hash:`0x${i.toString(16).padStart(64,'0')}`,contractAddress:at(i)}));
  j.receipts=j.transactions.map(t=>({...receipt,transactionHash:t.hash,contractAddress:t.contractAddress}));
 });
 let limited=false;
 const api=neckwork({submit:a=>a===at(2)&&!limited?(limited=true,[429,{statusCode:429,error:'Too Many Requests',message:'Rate limit exceeded, retry in 7 seconds'},{'retry-after':'7'}]):undefined});
 const r=await run([runs,`--out=${OUT}`,'--live'],api);
 assert.equal(r.code,0);
 const t=api.posts().map(p=>p.t);
 assert.equal(t.length,13);
 assert.ok(t[3]-t[2]>=7000,'retried after retry-after');
 for(let i=0;i+LIMITS.submits<t.length;i++)assert.ok(t[i+LIMITS.submits]-t[i]>=LIMITS.windowMs,`more than ${LIMITS.submits} submissions within a minute at ${i}`);
});

test('a rerun resumes jobs in flight instead of resubmitting, and resubmits jobs neckwork forgot', async () => {
 const state=join(temp(),'state.json');
 writeFileSync(state,JSON.stringify({[A.vault.toLowerCase()]:'job-41',[A.logic.toLowerCase()]:'job-lost'}));
 const api=neckwork({verified:[A.synth],jobs:{'job-41':['pending',{match:'exact_match',creationMatch:'exact_match'}]}});
 const r=await run([RUNS,`--out=${OUT}`,'--live'],api,{state});
 assert.equal(r.code,0);
 assert.deepEqual(api.posts().map(p=>p.url.slice(-42)),[A.logic,A.proxy]);
 assert.match(r.row('CollateralVault'),/exact_match, creation exact_match$/);
 assert.deepEqual(read(state),{});
});

test('only matching builds are submitted: metadata-only differences pass as partial', async () => {
 const runs=runsWith(j=>{
  const [synth,,proxy]=j.transactions;
  // another ipfs hash in the embedded metadata, then a changed opcode
  synth.transaction.input=synth.transaction.input.replace(/(a2646970667358221220)[0-9a-f]{4}/,'$1beef');
  proxy.transaction.input=proxy.transaction.input.replace('6080604052','6080604053');
 });
 const api=neckwork();
 const r=await run([runs,`--out=${OUT}`,'--live'],api);
 assert.equal(r.code,1);
 assert.deepEqual(api.posts().map(p=>p.url.slice(-42)),[A.synth,A.vault,A.logic]);
 assert.match(r.row('SyntheticToken'),/partial\s+exact_match$/);
 assert.match(r.row('ERC1967Proxy'),/mismatch\s+not submitted: mismatch$/);
 const code=MAIN.output.contracts['src/lib/CompoundLogic.sol'].CompoundLogic.evm.bytecode.object;
 assert.equal(compareInit(code,'0x'+code+'00'.repeat(32)),'exact');
 assert.equal(compareInit(code,code.slice(0,-2)),'mismatch');
 assert.equal(compareInit(code,code.replace(/(a2646970667358221220)../,'$100')),'partial');
});

test('--check only probes and needs no build', async () => {
 const api=neckwork({verified:[A.synth,A.vault]});
 const r=await run([RUNS,'--check','--out=/nonexistent'],api);
 assert.equal(r.code,1);
 assert.equal(api.posts().length,0);
 assert.match(r.row('CollateralVault'),/verified exact_match$/);
 assert.match(r.row('ERC1967Proxy'),/unverified$/);
});

test('lark journals and hardhat-deploy records', async () => {
 const journal=join(temp(),'journal.json');
 writeFileSync(journal,JSON.stringify({deployments:[
  {name:'SyntheticToken',label:'SyntheticToken',address:A.synth,block:1},{name:'CollateralVault',label:'CollateralVault',address:A.vault,block:2}],
  calls:[{label:'deploy.SyntheticToken',hash:TX[0]},{label:'deploy.CollateralVault',hash:TX[1]}],addresses:{vaultImpl:A.vault,compoundLogic:A.logic}}));
 const record=fileURLToPath(new URL('../../deployments/hydration/PRIME-CheckedOracle.json',import.meta.url));
 const dump=temp();
 const r=await run([journal,record,`--out=${OUT}`,`--dump=${dump}`],neckwork());
 assert.equal(r.code,0);
 for(const a of [A.synth,A.vault,A.logic])
  assert.deepEqual(read(join(dump,`${BODIES[a].contractIdentifier.split(':').at(-1)}-${a}.json`)),BODIES[a]);
 assert.match(r.row('CompoundLogic (in CollateralVault)'),/unchecked\s+would submit$/);
 assert.deepEqual(read(join(dump,'CheckedOracle-0x09221057Cf7E75953D199FB319E606972A6A82Cd.json')),{
  stdJsonInput:read(fileURLToPath(new URL('../../deployments/hydration/solcInputs/9da28d2a5d50bac15f144ef7c689df0b.json',import.meta.url))),
  compilerVersion:'0.8.10+commit.fc410830',contractIdentifier:'contracts/CheckedOracle.sol:CheckedOracle',
  creationTransactionHash:'0x279d292a1c029aa5c299e0669fcb480a70e619252cd8b7b7f57c2ccddba782b9'});
});

test('request bodies carry only sources the deployed metadata commits to', async () => {
 const edit=change=>{
  const out=temp();cpSync(OUT,out,{recursive:true});
  const file=join(out,'build-info/5f3a9c1e2b7d4a60.json'),b=read(file);change(b.input.sources);writeFileSync(file,JSON.stringify(b));
  return out;
 };
 const base='/build/money-market/bil-vault/lib/base/src/Base.sol';
 await assert.rejects(main([RUNS,`--out=${edit(s=>{s[base].content+='\n';})}`],{log:()=>{}}),/\.\.\/bil-vault\/lib\/base\/src\/Base\.sol is not the compiled source/);
 await assert.rejects(main([RUNS,`--out=${edit(s=>{delete s[base];})}`],{log:()=>{}}),/lacks \.\.\/bil-vault\/lib\/base\/src\/Base\.sol/);
});
