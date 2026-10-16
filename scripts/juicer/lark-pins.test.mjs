import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdtempSync,copyFileSync,readFileSync,writeFileSync,statSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {LARK4_IDENTITY as L4} from './lark4-identity.mjs';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {PROFILES,resolveProfile,requirePins,primeCapNeed,primeCapIds} from './lark-pins.mjs';
const here=fileURLToPath(new URL('.',import.meta.url)),fixture=name=>join(here,'fixtures',name);
const {mnemonicToAccount}=createRequire(import.meta.url)('viem/accounts'),{toHex}=createRequire(import.meta.url)('viem');
const key=index=>toHex(mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:index}).getHdKey().privateKey);
const IMAGES={KEEPER_IMAGE:`${L4.images.keeper}@sha256:${'a'.repeat(64)}`,BOT_IMAGE:`${L4.images.bots}@sha256:${'b'.repeat(64)}`};
// a clean environment: an operator's LARK_* or artifact variables must not leak into these runs
const run=(script,args,env)=>execFileSync(process.execPath,[join(here,script),...args],{env:{PATH:process.env.PATH,...env},encoding:'utf8'});
const dirs=[];
after(()=>{for(const dir of dirs)rmSync(dir,{recursive:true,force:true});});
function state(journal='lark4-journal.json',name='propeller-lark-20261007.json'){
 const dir=mkdtempSync(join(tmpdir(),'lark-pins-'));dirs.push(dir);copyFileSync(fixture(journal),join(dir,name));return dir;
}

test('lark4 is today\'s pinned chain, files and stack settings', () => {
 const p=resolveProfile('lark4',{});
 assert.equal(p.legacy,true);
 assert.equal(p.chainName,'Lark 4 Hydration');
 assert.equal(p.genesis,'0x0a1fba23f7897cb5cbb3289db93ab605774565149b0c87033b4f2af817c9f96c');
 assert.equal(p.deployment,'20261007');
 assert.equal(p.commit,'db0799c2c13cfea880b089d737c02cfb2e116be6');
 assert.deepEqual([p.rpc,p.ws],['https://node4.lark.hydration.cloud','wss://node4.lark.hydration.cloud']);
 assert.deepEqual(p.gateway,{rpc:'https://4.lark.hydration.cloud',ws:'wss://4.lark.hydration.cloud'});
 assert.deepEqual([p.journal,p.prices,p.manifest,p.stack.file],['/tmp/propeller-lark-20261007.json','/tmp/propeller-lark-prices-20261007.json','/tmp/propeller-lark-manifest-20261007.json',join('/tmp',L4.stackFile)]);
 assert.equal(p.stack.manifestConfig,'propeller-lark4-20261007-manifest-v3');
 assert.deepEqual(p.stack.keeperRpcUrls,['https://node4.lark.hydration.cloud','https://4.lark.hydration.cloud']);
 assert.deepEqual(p.stack.botEnv,{});
 assert.deepEqual(p.signers,{markets:'//Alice//propeller-20261005-arb',pools:'//Alice//propeller-20261007-pools',replay:'//Alice//propeller-20261007-replay'});
 assert.equal(p.hollarBucket,1000000n*10n**18n);
 assert.deepEqual(p.names.vaults,L4.names.vaults);
 assert.equal(p.artifactDir,L4.artifactDir);
 assert.deepEqual(p.primeLanes,{trade:1000,capacity:10000,refill:10,pegPrime:150000,approval:'make sure the lark4 prime loop leveraging continues'});
 assert.deepEqual(p.depositor,{durationS:259200,everyS:1800,delayS:null},'lark 4 always names its DEPOSIT_START');
 assert.deepEqual(p.images,L4.images);
});

test('pins are pins: the environment fills only open fields, the state dir moves only state files', () => {
 const p=resolveProfile('lark4',{LARK_RPC:'https://node9.lark.hydration.cloud',LARK_GENESIS:'0x00',LARK_STATE_DIR:'/var/lark'});
 assert.equal(p.rpc,'https://node4.lark.hydration.cloud');
 assert.equal(p.genesis,resolveProfile('lark4',{}).genesis);
 assert.equal(p.journal,'/var/lark/propeller-lark-20261007.json');
 assert.equal(p.stack.file,join('/var/lark',L4.stackFile));
 assert.equal(p.artifactDir,L4.artifactDir);
});

test('lark 0 is pinned but for the genesis and commit its refork brings', () => {
 const p=resolveProfile('lark0',{});
 assert.equal(p.legacy,false);
 assert.deepEqual([p.chainName,p.rpc,p.ws],['Lark 0 Hydration','https://node0.lark.hydration.cloud','wss://node0.lark.hydration.cloud']);
 assert.deepEqual(p.gateway,{rpc:p.rpc,ws:p.ws},'scripts and the journal stay on node0, off subway');
 assert.deepEqual([p.genesis,p.commit],[null,null]);
 assert.throws(()=>requirePins(p),/not pinned: set LARK_GENESIS or/);
 assert.equal(p.journal,'/tmp/juicer-lark-lark0-20261009.json');
 assert.notEqual(p.stack.file,resolveProfile('lark4',{}).stack.file,'never overwrites the lark 4 stack');
 assert.deepEqual([p.stack.file,p.stack.name,p.stack.manifestConfig],['/tmp/juicer-lark-stack-lark0-20261009.json','juicer-lark0-20261009','juicer-lark0-20261009-manifest-v1']);
 assert.deepEqual(p.stack.keeperRpcUrls,['https://node0.lark.hydration.cloud','https://0.lark.hydration.cloud']);
 assert.deepEqual(p.stack.botEnv,{LARK_RPC:'https://node0.lark.hydration.cloud',LARK_WS:'wss://node0.lark.hydration.cloud'});
 assert.deepEqual(p.names.vaults,{ETH:['Juicer ETH','jETH'],TBTC:['Juicer tBTC','jtBTC']});
 assert.deepEqual(p.names.synth,['Juicer Synthetic HOLLAR','jsHOLLAR']);
 assert.ok(Buffer.byteLength(p.names.asset)<=32,'asset registry string limit');
 assert.equal(p.hollarBucket,5000000n*10n**18n);
 const {trade,capacity,refill}=p.primeLanes;
 assert.deepEqual([trade,capacity,refill],[2500,25000,50]);
 assert.ok(refill*60>=trade,'the budget refills a trade within the 60 s pacing');
 assert.ok(400000/trade<=3*60,'~400k of PRIME buys take under 3 h of one-a-minute trades');
 assert.deepEqual(p.depositor,{durationS:36000,everyS:600,delayS:3600});
 assert.deepEqual(p.images,{keeper:'galacticcouncil/juicer-lark-keeper',bots:'galacticcouncil/juicer-lark-bots'});
 assert.ok(p.depositor.delayS+p.depositor.durationS<=12*3600,'the $100k plan lands within 12 h of the stack');
});

test('the refork\'s genesis and commit come from the environment, nothing else does', () => {
 const p=resolveProfile('lark0',{LARK_GENESIS:'0x07',LARK_COMMIT:'abc',LARK_RPC:'https://node9.lark.hydration.cloud',LARK_CHAIN_NAME:'Lark 9'});
 assert.equal(requirePins(p),p);
 assert.deepEqual([p.genesis,p.commit,p.rpc,p.chainName],['0x07','abc','https://node0.lark.hydration.cloud','Lark 0 Hydration']);
});

test('lark tooling refuses unknown profiles and non-lark chains', () => {
 assert.throws(()=>resolveProfile('mainnet',{}),/unknown lark profile/);
 PROFILES.open={...PROFILES.lark0,chainName:null,rpc:null,ws:null,gateway:undefined};
 try{
  assert.throws(()=>resolveProfile('open',{LARK_CHAIN_NAME:'Hydration'}),/non-lark/);
  const p=resolveProfile('open',{LARK_CHAIN_NAME:'Lark 7 Hydration',LARK_RPC:'https://node7.lark.hydration.cloud'});
  assert.deepEqual([p.chainName,p.ws],['Lark 7 Hydration','wss://node7.lark.hydration.cloud'],'an open endpoint takes the environment, ws derived');
 }finally{delete PROFILES.open;}
});

test('scripts resolve the profile from --profile or LARK_PROFILE, lark4 by default', () => {
 const probe="import('./lark-pins.mjs').then(m=>console.log(JSON.stringify([m.profile.name,m.GENESIS,m.DEPLOYMENT,m.CORE_FILE,m.FILE,m.PRICES_FILE,m.MANIFEST_CONFIG,process.env.JUICER_ARTIFACT_DIR])))";
 const exec=(args,env)=>JSON.parse(execFileSync(process.execPath,['--input-type=module','-e',probe,'--',...args],{cwd:here,env:{PATH:process.env.PATH,...env},encoding:'utf8'}));
 assert.deepEqual(exec([],{}),['lark4','0x0a1fba23f7897cb5cbb3289db93ab605774565149b0c87033b4f2af817c9f96c','20261007','/tmp/propeller-lark-20261007.json','/tmp/propeller-lark-20261007.json','/tmp/propeller-lark-prices-20261007.json','propeller-lark4-20261007-manifest-v3',L4.artifactDir]);
 assert.equal(exec([],{JUICER_LARK_RESULT:'/x/prices.json',JUICER_ARTIFACT_DIR:'/x/out'})[4],'/x/prices.json');
 assert.equal(exec([],{JUICER_ARTIFACT_DIR:'/x/out'})[7],'/x/out');
 assert.equal(exec(['--profile=lark0'],{})[0],'lark0');
 assert.equal(exec([],{LARK_PROFILE:'lark0'})[0],'lark0');
});

test('the lark 4 manifest and stack come out exactly as before profiles', () => {
 const dir=state();
 assert.equal(run('lark-manifest.mjs',[],{LARK_STATE_DIR:dir}).trim(),join(dir,'propeller-lark-manifest-20261007.json'));
 assert.equal(readFileSync(join(dir,'propeller-lark-manifest-20261007.json'),'utf8'),readFileSync(fixture('lark4-manifest.json'),'utf8'));
 for(const [args,golden,env] of [[['--keepers','--depositor'],'lark4-stack-keepers-depositor.json',{DEPOSIT_START:'1791378922',DEPOSIT_DURATION_S:'27000',DEPOSIT_EVERY_S:'600'}],[[],'lark4-stack-drained.json',{}]]){
  run('lark-stack.mjs',args,{LARK_STATE_DIR:dir,...IMAGES,...env});
  const file=join(dir,L4.stackFile);
  assert.equal(statSync(file).mode&0o777,0o600);
  // public dev keys are derived, never committed
  let text=readFileSync(file,'utf8');
  for(const index of [18,20]){assert.ok(text.includes(key(index)));text=text.split(key(index)).join(`<testAccount(${index}) key>`);}
  assert.equal(text,readFileSync(fixture(golden),'utf8'),golden);
 }
});

test('lark 4 and lark 0 keep minted, mirrored ETH and tBTC behind their vaults', () => {
 for(const name of ['lark4','lark0'])assert.deepEqual(resolveProfile(name,{}).collateral,{ETH:{assetId:34,symbol:'ETH'},TBTC:{assetId:1000765,symbol:'tBTC'}},name);
});

test('next is lark 0\'s plan on a chain to come: GIGAETH behind jETH, jBTC on tBTC', () => {
 const p=resolveProfile('next',{LARK_DEPLOYMENT:'next-20261020'}),lark0=resolveProfile('lark0',{});
 assert.equal(p.legacy,false);
 assert.deepEqual([p.chainName,p.genesis,p.commit,p.rpc,p.ws],[null,null,null,null,null]);
 assert.throws(()=>requirePins(p),/not pinned: set LARK_CHAIN_NAME, LARK_GENESIS, LARK_RPC/);
 assert.deepEqual([p.journal,p.prices,p.manifest,p.bringUp],['/tmp/juicer-lark-next-20261020.json','/tmp/juicer-lark-prices-next-20261020.json','/tmp/juicer-lark-manifest-next-20261020.json','/tmp/juicer-lark-bringup-next-20261020.json']);
 assert.deepEqual([p.stack.file,p.stack.name,p.stack.manifestConfig],['/tmp/juicer-lark-stack-next-20261020.json','juicer-next-20261020','juicer-next-20261020-manifest-v1']);
 assert.deepEqual(p.names.vaults,{ETH:['Juicer ETH','jETH'],TBTC:['Juicer BTC','jBTC']});
 for(const k of ['synth','asset','aToken','variableDebt','stableDebt'])assert.deepEqual(p.names[k],lark0.names[k],k);
 const {ETH,TBTC}=p.collateral;
 assert.deepEqual([ETH.assetId,ETH.symbol,ETH.mirror,ETH.buy.from],[4200,'GIGAETH',false,34]);
 assert.deepEqual(ETH.buy.route,[{pool:'Aave',assetIn:34,assetOut:1007},{pool:{Stableswap:4200},assetIn:1007,assetOut:4200}],'ETH into aETH, then pool 4200 shares');
 assert.deepEqual(TBTC,lark0.collateral.TBTC);
 for(const k of ['signers','hollarBucket','primeLanes','primePool','depositor','images'])assert.deepEqual(p[k],lark0[k],k);
 assert.deepEqual([p.stack.keeperEnv,p.stack.keeperRpcUrls],[lark0.stack.keeperEnv,[]]);
 assert.deepEqual(p.stack.bots,{...lark0.stack.bots,markets:{BOT_INTERVAL_MS:'5000',PEG_SELL_PROFIT_BPS:'15',PEG_BUY_PROFIT_BPS:'4'}});
});

test('next\'s PRIME arb trades at mainnet\'s thresholds, and its lanes take the band it leaves', () => {
 const p=resolveProfile('next',{LARK_DEPLOYMENT:'next-1'}),lark0=resolveProfile('lark0',{});
 assert.deepEqual([lark0.peg,lark0.primeCap,lark0.primePool.feePpm],[null,{shortfallBps:6,approval:'Use 6 bps on Lark only (Recommended)'},null],'lark 0 keeps its fee-paying peg at 6 bps');
 assert.deepEqual(p.peg,{sellProfitBps:15,buyProfitBps:4});
 assert.deepEqual([p.stack.bots.markets.PEG_SELL_PROFIT_BPS,p.stack.bots.markets.PEG_BUY_PROFIT_BPS],[String(p.peg.sellProfitBps),String(p.peg.buyProfitBps)]);
 assert.equal(primeCapNeed(400,p.peg),25,'pool 143 charges 4 bps on mainnet');
 assert.ok(p.primeCap.shortfallBps>=primeCapNeed(400,p.peg)+2,'two bps to spare for replayed flow');
 assert.equal(primeCapNeed(200,p.peg),21,'a 2 bps fee saves the loop 4');
 assert.equal(primeCapNeed(400,{sellProfitBps:0,buyProfitBps:0}),10,'a break-even arb needs 10');
 assert.deepEqual(primeCapIds(lark0.primeCap.shortfallBps),{approval:'prime-six-bps',label:'approved-lark-only-prime-six-bps'},'lark 0 resumes its own referendum');
 assert.deepEqual(primeCapIds(p.primeCap.shortfallBps),{approval:'prime-27-bps',label:'approved-lark-only-prime-27-bps'});
});

test('next takes its chain, endpoints and deployment id from the environment, never another profile\'s files', () => {
 assert.throws(()=>resolveProfile('next',{}),/no deployment id: set LARK_DEPLOYMENT/);
 for(const d of ['lark0-20261009','20261007'])assert.throws(()=>resolveProfile('next',{LARK_DEPLOYMENT:d}),/belongs to another profile/);
 for(const d of ['../lark','Next','next 1'])assert.throws(()=>resolveProfile('next',{LARK_DEPLOYMENT:d}),/LARK_DEPLOYMENT/);
 assert.throws(()=>resolveProfile('next',{LARK_DEPLOYMENT:'next-1',LARK_CHAIN_NAME:'Hydration'}),/non-lark/);
 const p=resolveProfile('next',{LARK_DEPLOYMENT:'next-1',LARK_CHAIN_NAME:'Lark 9 Hydration',LARK_GENESIS:'0x09',LARK_COMMIT:'abc',LARK_RPC:'https://node9.lark.hydration.cloud',LARK_STATE_DIR:'/var/lark'});
 assert.equal(requirePins(p),p);
 assert.deepEqual([p.chainName,p.genesis,p.commit,p.ws],['Lark 9 Hydration','0x09','abc','wss://node9.lark.hydration.cloud']);
 assert.deepEqual(p.gateway,{rpc:p.rpc,ws:p.ws});
 assert.equal(p.journal,'/var/lark/juicer-lark-next-1.json');
 assert.deepEqual(p.stack.keeperRpcUrls,['https://node9.lark.hydration.cloud']);
 assert.deepEqual(p.stack.botEnv,{LARK_RPC:'https://node9.lark.hydration.cloud',LARK_WS:'wss://node9.lark.hydration.cloud'});
 assert.equal(resolveProfile('lark0',{LARK_DEPLOYMENT:'next-1'}).deployment,'lark0-20261009','a pinned id stays pinned');
});

test('scripts pick next from LARK_PROFILE and refuse it without a deployment id', () => {
 const probe="import('./lark-pins.mjs').then(m=>console.log(JSON.stringify([m.profile.name,m.DEPLOYMENT,m.CORE_FILE,m.PRICES_FILE,m.MANIFEST_CONFIG])))";
 const exec=env=>spawnSync(process.execPath,['--input-type=module','-e',probe],{cwd:here,env:{PATH:process.env.PATH,...env},encoding:'utf8'});
 const out=exec({LARK_PROFILE:'next',LARK_DEPLOYMENT:'next-x'});
 assert.equal(out.status,0,out.stderr);
 assert.deepEqual(JSON.parse(out.stdout),['next','next-x','/tmp/juicer-lark-next-x.json','/tmp/juicer-lark-prices-next-x.json','juicer-next-x-manifest-v1']);
 assert.match(exec({LARK_PROFILE:'next'}).stderr,/set LARK_DEPLOYMENT/);
});

test('the next manifest marks GIGAETH\'s forked source, the one oracle the bots never mirror', () => {
 const dir=mkdtempSync(join(tmpdir(),'lark-pins-'));dirs.push(dir);
 const r=JSON.parse(readFileSync(fixture('lark4-journal.json'),'utf8')),genesis=`0x${'99'.repeat(32)}`,rpc='https://node9.lark.hydration.cloud',giga='0x0000000000000000000000000000000100001068';
 r.oracles[0]={assetId:4200,asset:giga,name:'GIGAETH',address:'0x00000000000000000000000000000000000000a4',mirror:false};
 r.vaults[0]={...r.vaults[0],assetId:4200,asset:giga};
 writeFileSync(join(dir,'juicer-lark-next-9.json'),JSON.stringify({...r,rpc,genesis}));
 const env={LARK_PROFILE:'next',LARK_DEPLOYMENT:'next-9',LARK_CHAIN_NAME:'Lark 9 Hydration',LARK_GENESIS:genesis,LARK_RPC:rpc,LARK_STATE_DIR:dir};
 assert.equal(run('lark-manifest.mjs',[],env).trim(),join(dir,'juicer-lark-manifest-next-9.json'));
 const m=JSON.parse(readFileSync(join(dir,'juicer-lark-manifest-next-9.json'),'utf8'));
 assert.deepEqual(m.oracles.map(o=>[o.assetId,o.mirror]),[[4200,false],[1000765,undefined],[43,undefined]]);
 assert.ok(m.oracles.slice(1).every(o=>!('mirror' in o)),'mirror rows keep their shape');
 assert.deepEqual([m.chainName,m.vaults.map(v=>v.assetId)],['Lark 9 Hydration',[4200,1000765]]);
});
