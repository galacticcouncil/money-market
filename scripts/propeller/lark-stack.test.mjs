import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,statSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
const here=fileURLToPath(new URL('.',import.meta.url));
const {mnemonicToAccount}=createRequire(import.meta.url)('viem/accounts'),{toHex}=createRequire(import.meta.url)('viem');
const key=index=>toHex(mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:index}).getHdKey().privateKey);
const LARK0={LARK_PROFILE:'lark0',LARK_GENESIS:`0x${'77'.repeat(32)}`},NODE0='https://node0.lark.hydration.cloud',ID='lark0-20261009';
const IMAGES={KEEPER_IMAGE:`galacticcouncil/propeller-lark-keeper@sha256:${'c'.repeat(64)}`,BOT_IMAGE:`galacticcouncil/propeller-lark-bots@sha256:${'d'.repeat(64)}`};
const run=(script,args,env)=>spawnSync(process.execPath,[join(here,script),...args],{env:{PATH:process.env.PATH,...env},encoding:'utf8'});
// the synthetic lark 4 journal, moved to the new chain
const dirs=[];
after(()=>{for(const dir of dirs)rmSync(dir,{recursive:true,force:true});});
function lark0State(){
 const dir=mkdtempSync(join(tmpdir(),'lark-stack-'));dirs.push(dir);
 const r=JSON.parse(readFileSync(join(here,'fixtures','lark4-journal.json'),'utf8'));
 writeFileSync(join(dir,`propeller-lark-${ID}.json`),JSON.stringify({...r,rpc:NODE0,genesis:LARK0.LARK_GENESIS}));
 return dir;
}

test('the lark 0 stack names its own chain, stack and config, never lark 4', () => {
 const dir=lark0State(),out=run('lark-stack.mjs',['--keepers'],{...LARK0,...IMAGES,LARK_STATE_DIR:dir});
 assert.equal(out.status,0,out.stderr);
 const summary=JSON.parse(out.stdout);
 assert.equal(summary.file,join(dir,`propeller-lark-stack-${ID}.json`));
 assert.deepEqual([summary.stack,summary.manifestConfig],[`propeller-${ID}`,`propeller-${ID}-manifest-v1`]);
 const text=readFileSync(summary.file,'utf8'),compose=JSON.parse(text);
 assert.equal(statSync(summary.file).mode&0o777,0o600);
 assert.doesNotMatch(text,/node4|4\.lark|lark4|20261007/);
 assert.deepEqual(Object.keys(compose.services),['keeper0','keeper1','mirror','markets','pools','replay']);
 assert.deepEqual(compose.configs,{propeller_manifest:{external:true,name:`propeller-${ID}-manifest-v1`}});
 for(const [i,index]of [[0,18],[1,20]]){
  const k=compose.services[`keeper${i}`];
  assert.equal(k.image,IMAGES.KEEPER_IMAGE);
  assert.equal(k.deploy.replicas,1);
  assert.equal(k.environment.LOOPER_PRIVATE_KEY,key(index));
  assert.deepEqual([k.environment.RPC_URL,k.environment.RPC_URLS],[NODE0,`${NODE0},https://0.lark.hydration.cloud`],'node0 first, subway only as fallback');
  assert.equal(k.environment.QUOTE_DEPTH_BLOCKS,'3');
  assert.deepEqual([k.environment.OPERATOR_COUNT,k.environment.OPERATOR_INDEX],['2',String(i)]);
 }
 for(const mode of ['mirror','markets','pools','replay']){
  const b=compose.services[mode];
  assert.equal(b.image,IMAGES.BOT_IMAGE);
  assert.equal(b.environment.BOT_MODE,mode);
  assert.deepEqual([b.environment.LARK_RPC,b.environment.LARK_WS],[NODE0,'wss://node0.lark.hydration.cloud']);
 }
 assert.equal(compose.services.markets.environment.PEG_BAND_BPS,'0.5');
 assert.deepEqual(Object.keys(compose.services.markets.environment),['BOT_MODE','BOT_LIVE','BOT_MANIFEST','BOT_INTERVAL_MS','PEG_BAND_BPS','LARK_RPC','LARK_WS']);
});

test('images go in by digest only, and keepers stay drained without --keepers', () => {
 const dir=lark0State();
 for(const tag of [{KEEPER_IMAGE:'galacticcouncil/propeller-lark-keeper:latest'},{BOT_IMAGE:`galacticcouncil/propeller-lark-bots:sha256-${'d'.repeat(64)}`}])
  assert.notEqual(run('lark-stack.mjs',['--keepers'],{...LARK0,...IMAGES,...tag,LARK_STATE_DIR:dir}).status,0);
 const out=run('lark-stack.mjs',[],{...LARK0,...IMAGES,LARK_STATE_DIR:dir});
 assert.equal(out.status,0,out.stderr);
 const compose=JSON.parse(readFileSync(join(dir,`propeller-lark-stack-${ID}.json`),'utf8'));
 assert.deepEqual([compose.services.keeper0.deploy.replicas,compose.services.mirror.deploy.replicas],[0,1]);
});

test('a journal from another chain or an unpinned profile writes no stack', () => {
 const dir=lark0State();
 assert.match(run('lark-stack.mjs',['--keepers'],{...LARK0,...IMAGES,LARK_GENESIS:`0x${'88'.repeat(32)}`,LARK_STATE_DIR:dir}).stderr,/AssertionError/);
 assert.match(run('lark-stack.mjs',['--keepers'],{LARK_PROFILE:'lark0',...IMAGES,LARK_STATE_DIR:dir}).stderr,/not pinned/);
});

test('the lark 0 manifest tells the bots which chain and signers they run on', () => {
 const dir=lark0State(),out=run('lark-manifest.mjs',[],{...LARK0,LARK_STATE_DIR:dir});
 assert.equal(out.status,0,out.stderr);
 const manifest=JSON.parse(readFileSync(join(dir,`propeller-lark-manifest-${ID}.json`),'utf8'));
 assert.equal(manifest.chainName,'Lark 0 Hydration');
 assert.equal(manifest.genesis,LARK0.LARK_GENESIS);
 assert.deepEqual(Object.keys(manifest.signers),['markets','pools','replay']);
});

test('the lark 0 depositor runs ten hours, every ten minutes, a set delay after the stack', () => {
 const dir=lark0State(),now=Math.floor(Date.now()/1000);
 const read=env=>{
  const out=run('lark-stack.mjs',['--keepers','--depositor'],{...LARK0,...IMAGES,LARK_STATE_DIR:dir,...env});
  assert.equal(out.status,0,out.stderr);
  return [JSON.parse(out.stdout),JSON.parse(readFileSync(join(dir,`propeller-lark-stack-${ID}.json`),'utf8')).services.depositor.environment];
 };
 const [summary,env]=read({});
 assert.deepEqual([env.DEPOSIT_DURATION_S,env.DEPOSIT_EVERY_S,env.LARK_RPC],['36000','600',NODE0]);
 assert.ok(Math.abs(Number(env.DEPOSIT_START)-(now+3600))<=60,'an hour after the stack by default');
 assert.equal(summary.depositStart,env.DEPOSIT_START);
 assert.ok(Math.abs(Number(read({DEPOSIT_DELAY_S:'600'})[1].DEPOSIT_START)-(now+600))<=60);
 assert.equal(read({DEPOSIT_START:'1800000000'})[1].DEPOSIT_START,'1800000000');
});
