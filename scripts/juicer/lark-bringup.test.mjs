import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {existsSync,mkdtempSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {LARK4_IDENTITY as L4} from './lark4-identity.mjs';
import {fileURLToPath} from 'node:url';
import {STEPS,stepStatus,schedule,missing} from './lark-bringup-steps.mjs';
import {resolveProfile} from './lark-pins.mjs';
const here=fileURLToPath(new URL('.',import.meta.url));
const step=id=>STEPS.find(s=>s.id===id);
// the journal markers each step leaves once it is complete
const LARK0=resolveProfile('lark0',{});
function complete(ids){
 const core={checks:{},governance:[],vaults:[]},prices={addresses:{}};
 const verified=label=>core.governance.push({label,verified:true});
 const marks={
  chain:()=>core.checks.chain=true,prepare:()=>core.checks.testAccountsFunded=true,'prime-pool':()=>core.checks.primePool=true,
  deploy:()=>core.vaults.push({name:'ETH',rounding:{}},{name:'TBTC',rounding:{}}),wire:()=>verified('bind-execution-controller'),
  prices:()=>prices.oracles=[{},{},{}],discount:()=>prices.addresses.discount='0x01',market:()=>verified('testnet-guardians-and-open-bootstrap'),
  bootstrap:()=>core.checks.bootstrapNoBorrow=true,'prime-cap':()=>verified('arb.refill-hollar-with-quote-reserve'),adapter:()=>core.checks.adapterWhitelisted=true,
  routes:()=>core.checks.primeCollateralRoutes=true,'harvest-cap':()=>verified('approved-lark-only-collateral-hundred-bps'),throughput:()=>verified('lark-prime-tranches-2500'),
  sync:()=>core.checks.mainnetSync=true,'sync-inventory':()=>core.checks.syncInventory=true,wrap:()=>verified('pools-underlying-stash'),
  stable:()=>verified('pools-stable-inventory'),release:()=>core.checks.depositRelease=true,seed:()=>verified('bots-seed-baseline'),
  params:()=>core.checks.nextParameters={},guardian:()=>core.checks.depositGuardian={},ice:()=>core.checks.iceWiring=true,
  depositors:()=>core.checks.depositorFunded=true,'depositor-approve':()=>core.checks.depositorApproved=true,
 };
 for(const id of ids)marks[id]();
 return {profile:LARK0,core,prices};
}
const before=id=>STEPS.slice(0,STEPS.findIndex(s=>s.id===id)).filter(s=>!s.output).map(s=>s.id);
const dirs=[],scratch=()=>{const dir=mkdtempSync(join(tmpdir(),'lark-bringup-'));dirs.push(dir);return dir;};
after(()=>{for(const dir of dirs)rmSync(dir,{recursive:true,force:true});});
const run=(args,env)=>spawnSync(process.execPath,[join(here,'lark-bringup.mjs'),...args],{env:{PATH:process.env.PATH,...env},encoding:'utf8'});

test('the bring-up runs the existing step scripts in the deployment order', () => {
 const ids=STEPS.map(s=>s.id);
 assert.equal(new Set(ids).size,ids.length);
 for(const s of STEPS)assert.ok(existsSync(join(here,s.script)),s.script);
 assert.deepEqual(ids.slice(0,2),['chain','prepare']);
 assert.deepEqual(ids.slice(-2),['manifest','stack']);
 assert.deepEqual(STEPS.filter(s=>s.output).map(s=>s.id),['manifest','stack']);
 for(const [a,b]of [['deploy','wire'],['wire','prices'],['prices','discount'],['discount','market'],['market','bootstrap'],['bootstrap','prime-cap'],['wire','throughput'],['sync','sync-inventory'],['throughput','seed'],['wire','params']])
  assert.ok(ids.indexOf(a)<ids.indexOf(b),`${a} before ${b}`);
 assert.deepEqual(STEPS.filter(s=>s.journal==='prices').map(s=>s.id),['prices','discount']);
 assert.deepEqual(step('seed').args,['--round=baseline']);
 assert.deepEqual(step('stack').args,['--keepers','--depositor']);
 assert.ok(ids.indexOf('depositor-approve')<ids.indexOf('manifest'),'the manifest carries the depositor plan');
});

test('no nurse or Main cushions, and no placeholders left', () => {
 for(const script of ['lark-nurse.mjs','lark-fund-main.mjs','lark-recap-source.mjs','lark-fund-exit.mjs']){
  assert.ok(!STEPS.some(s=>s.script===script),script);
  assert.match(readFileSync(join(here,script),'utf8'),/assert\.ok\(profile\.legacy,/,`${script} refuses the next version`);
 }
 for(const s of STEPS)assert.doesNotMatch(readFileSync(join(here,s.script),'utf8'),/PLACEHOLDER|assert\.fail\(/,s.script);
});

test('steps whose script demands --live are never dry-run', () => {
 for(const s of STEPS.filter(s=>!s.output)){
  const demands=/^\s*assert\.ok\(live[,)]/m.test(readFileSync(join(here,s.script),'utf8'));
  assert.equal(!!s.live,demands,s.id);
 }
});

test('journal markers complete each step', () => {
 const empty=complete([]);
 for(const s of STEPS)assert.equal(stepStatus(s,empty),s.output?'output':'pending',s.id);
 const all=complete(STEPS.filter(s=>!s.output).map(s=>s.id));
 for(const s of STEPS.filter(s=>!s.output))assert.equal(stepStatus(s,all),'done',s.id);
 assert.equal(stepStatus(step('deploy'),{core:{vaults:[{name:'ETH',rounding:{}}]}}),'pending','one vault is not a deployment');
 const lark4=complete([]);lark4.profile=resolveProfile('lark4',{});lark4.core.governance.push({label:'lark-prime-tranches-1000',verified:true});
 assert.equal(stepStatus(step('throughput'),lark4),'done','each profile finishes its own lane size');
 assert.equal(stepStatus(step('throughput'),{...lark4,profile:LARK0}),'pending');
});

test('a dry run validates only the next step; a live run walks on, skipping only on request', () => {
 assert.equal(schedule(STEPS,complete([])).run.id,'chain');
 assert.equal(schedule(STEPS,complete(before('wire'))).run.id,'wire');
 const dry=schedule(STEPS,complete(before('deploy')));
 assert.equal(dry.stop.id,'deploy');assert.match(dry.reason,/--live/);
 assert.equal(schedule(STEPS,complete(before('deploy')),{live:true}).run.id,'deploy');
 const atGuardian=complete(before('guardian'));
 for(const live of [false,true])assert.equal(schedule(STEPS,atGuardian,{live}).run.id,'guardian');
 assert.equal(schedule(STEPS,atGuardian,{live:true,skip:new Set(['guardian'])}).skip.id,'guardian');
 assert.equal(schedule(STEPS,atGuardian,{live:true,skip:new Set(['guardian']),ran:new Set(['guardian'])}).run.id,'ice');
 const past=complete(before('manifest'));
 assert.equal(schedule(STEPS,past),null,'outputs are never written by a dry run');
 assert.equal(schedule(STEPS,past,{live:true}).run.id,'manifest');
 assert.equal(schedule(STEPS,past,{live:true,ran:new Set(['manifest'])}).run.id,'stack');
 assert.equal(schedule(STEPS,past,{live:true,ran:new Set(['manifest','stack'])}),null);
 assert.equal(schedule(STEPS,past,{only:'wire'}).run.id,'wire','--only reruns a finished step');
 assert.equal(schedule(STEPS,complete(['chain']),{from:'wire'}).run.id,'wire');
});

test('a step names what it still needs before it starts', () => {
 const lark0=resolveProfile('lark0',{}),pinned=resolveProfile('lark0',{LARK_GENESIS:'0x09',LARK_COMMIT:'abc'});
 assert.deepEqual(missing(step('chain'),lark0,{}),['LARK_GENESIS','LARK_COMMIT','JUICER_ARTIFACT_DIR']);
 assert.deepEqual(missing(step('deploy'),pinned,{JUICER_ARTIFACT_DIR:'/x'}),['JUICER_ADAPTER_ARTIFACT']);
 assert.deepEqual(missing(step('stack'),pinned,{KEEPER_IMAGE:'galacticcouncil/juicer-lark-keeper:latest'}),['KEEPER_IMAGE','BOT_IMAGE']);
 assert.deepEqual(missing(step('stack'),pinned,{KEEPER_IMAGE:`galacticcouncil/juicer-lark-keeper@sha256:${'1'.repeat(64)}`,BOT_IMAGE:`galacticcouncil/juicer-lark-bots@sha256:${'2'.repeat(64)}`}),[]);
 assert.deepEqual(missing(step('stack'),pinned,{KEEPER_IMAGE:`${L4.images.keeper}@sha256:${'1'.repeat(64)}`,BOT_IMAGE:`galacticcouncil/juicer-lark-bots@sha256:${'2'.repeat(64)}`}),['KEEPER_IMAGE'],'lark 0 runs the renamed images');
 assert.deepEqual(missing(step('wire'),resolveProfile('lark4',{}),{}),[]);
});

test('--plan shows lark 0 from zero and writes nothing', () => {
 const dir=scratch();
 const out=run(['--profile=lark0','--plan'],{LARK_STATE_DIR:dir});
 assert.equal(out.status,0,out.stderr);
 assert.match(out.stdout,/bring-up lark0: deployment lark0-20261009, chain Lark 0 Hydration, genesis unpinned/);
 assert.match(out.stdout,/ 1 chain +pending/);
 assert.match(out.stdout,/22 guardian +pending +DEPOSIT_GUARDIAN_ROLE \(setDeficitStop only\)/);
 assert.match(out.stdout,/24 depositors +pending/);
 assert.match(out.stdout,/27 stack +output +swarm stack: keepers on, depositor an hour after it is written/);
 assert.match(out.stdout,/unset: LARK_GENESIS, LARK_COMMIT, JUICER_ARTIFACT_DIR, JUICER_ADAPTER_ARTIFACT, KEEPER_IMAGE, BOT_IMAGE/);
 assert.ok(!existsSync(join(dir,'juicer-lark-bringup-lark0-20261009.json')));
});

test('an unpinned chain stops before any step script runs, and the stop is logged', () => {
 const dir=scratch();
 const out=run(['--profile=lark0'],{LARK_STATE_DIR:dir});
 assert.equal(out.status,1);
 assert.match(out.stdout,/STOP chain needs LARK_GENESIS, LARK_COMMIT/);
 assert.doesNotMatch(out.stdout,/RUN /);
 const log=JSON.parse(readFileSync(join(dir,'juicer-lark-bringup-lark0-20261009.json'),'utf8'));
 assert.equal(log.events.length,1);
 assert.equal(log.events[0].step,'chain');assert.equal(log.events[0].mode,'dry-run');assert.match(log.events[0].stopped,/unset/);
});

test('lark 4 is already up: only --plan runs against it', () => {
 const dir=scratch();
 const out=run([],{LARK_STATE_DIR:dir});
 assert.notEqual(out.status,0);
 assert.match(out.stderr,/already up/);
 assert.equal(run(['--plan'],{LARK_STATE_DIR:dir}).status,0);
});
