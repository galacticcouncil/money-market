import test from 'node:test';
import assert from 'node:assert/strict';
import {CAPS,POOL_STASH,parseReports,demands,recipe,planRefills,lastRefills,toUnits,fromUnits} from './lark-refill-plan.mjs';
const T0=Date.parse('2026-10-09T10:00:00.000Z'),at=min=>new Date(T0+min*60000).toISOString();
// rows as lark-bots/index.mjs logs them, behind docker/swarm prefixes
const LOG=[
 `juicer-next_markets.1.k2j@lark3    | {"time":"${at(1)}","mode":"markets","name":"inventory-refill-needed","asset":43,"balance":"1200000","premiumCbps":"567"}`,
 `{"time":"${at(2)}","mode":"markets","name":"peg","premiumCbps":"50","band":"50"}`,
 `{"time":"${at(3)}","mode":"pools","name":"inventory-refill-needed","asset":5,"wraps":1001,"balance":"0"}`,
 `{"time":"${at(4)}","mode":"pools","name":"inventory-refill-needed","asset":1001,"balance":"10","gainBps":"1"}`,
 `{"time":"${at(5)}","mode":"replay","name":"replay-window","mainnetFrom":1,"mainnetTo":20,"trades":9,"submitting":7,"skippedInputs":[22,1003]}`,
 'not json at all',
 `{"time":"${at(-120)}","mode":"pools","name":"inventory-refill-needed","asset":22,"balance":"0"}`,
 `{"time":"${at(6)}","mode":"markets","name":"inventory-refill-needed","asset":43,"balance":"900000","premiumCbps":"601"}`,
].join('\n');
const isToken=id=>[0,5,10,22,34,40,43,1000765,1000809].includes(id);
const DECIMALS={5:10,10:6,22:6,40:9,43:6,222:18,1000765:18,1000809:18};

test('bot logs become refill demands, latest report per bot and asset', () => {
 const reports=parseReports(LOG,{since:T0});
 assert.deepEqual(reports.map(r=>`${r.bot}:${r.asset}`),['markets:43','pools:5','pools:1001','replay:22','replay:1003','markets:43']);
 const wanted=demands(reports);
 assert.deepEqual(wanted.map(r=>`${r.bot}:${r.asset}`),['markets:43','pools:5','pools:1001','replay:22','replay:1003']);
 assert.equal(wanted[0].time,T0+6*60000);
 assert.equal(parseReports(LOG,{since:T0-180*60000}).filter(r=>r.asset===22).length,2,'older reports count when asked');
});

test('each report maps to what is minted, supplied and capped', () => {
 assert.equal(recipe('pools',1,isToken),null,'never mints the hub asset');
 assert.deepEqual(recipe('markets',222,isToken),{held:222,mint:222});
 assert.deepEqual(recipe('pools',1001,isToken),{held:5,mint:5},'pools wraps aDOT from its DOT stash itself');
 assert.deepEqual(recipe('pools',420,isToken),{held:1000809,mint:1000809});
 assert.deepEqual(recipe('replay',1003,isToken),{held:1003,mint:22,aToken:1003});
 assert.deepEqual(recipe('replay',22,isToken),{held:22,mint:22});
 assert.equal(recipe('replay',4200,isToken),null,'a non-token without a recipe waits for a hand seed');
 assert.ok(Object.values(POOL_STASH).every(id=>CAPS.pools[id]!==undefined),'every pools stash has a ceiling');
});

const base={isToken,decimals:DECIMALS,caps:CAPS,now:T0+10*60000,minIntervalMs:6*3600000};
test('a refill tops up to the cap and never past it', () => {
 const {plan,skipped}=planRefills({...base,wanted:[{bot:'markets',asset:43}],held:{'markets:43':fromUnits(10000,6)}});
 assert.deepEqual(plan,[['markets',43,490000]]);
 assert.deepEqual(skipped,[]);
 assert.deepEqual(planRefills({...base,wanted:[{bot:'markets',asset:43}],held:{'markets:43':fromUnits(250000,6)}}).skipped.map(s=>s.reason),['holds half its cap or more']);
 const atoken=planRefills({...base,wanted:[{bot:'replay',asset:1003}],held:{'replay:1003':fromUnits(1000.5,6)}});
 assert.deepEqual(atoken.plan,[['replay',22,298999.5,1003]],'aUSDC refills mint USDC and supply it');
 const btc=planRefills({...base,wanted:[{bot:'replay',asset:1006}],caps:{replay:{1006:0.5}},decimals:{1000765:18},isToken:()=>false,held:{}});
 assert.deepEqual(btc.plan,[['replay',1000765,0.5,1006]]);
});

test('a bot and asset refill at most once per interval', () => {
 const wanted=[{bot:'markets',asset:43}],held={};
 const recent=planRefills({...base,wanted,held,last:{'markets:43':T0}});
 assert.deepEqual(recent.plan,[]);
 assert.match(recent.skipped[0].reason,/refilled 10 min ago/);
 assert.equal(planRefills({...base,wanted,held,last:{'markets:43':T0-7*3600000}}).plan.length,1);
});

test('deposit fuse and facilitator room clamp a round, shared across bots', () => {
 const wanted=[{bot:'markets',asset:222},{bot:'pools',asset:222},{bot:'replay',asset:222}];
 const room=fromUnits(300000,18);
 const {plan,skipped}=planRefills({...base,wanted,held:{},headroom:{222:room}});
 assert.deepEqual(plan,[['markets',222,60000],['pools',222,200000]]);
 assert.match(skipped[0].reason,/under a tenth/,'replay waits: only 10k of 270k usable room is left');
 const used=plan.reduce((a,[,,n])=>a+fromUnits(n,18),0n);
 assert.ok(used<=room*9n/10n,'a tenth of the room stays free');
 const clamped=planRefills({...base,wanted:[{bot:'markets',asset:43}],held:{},headroom:{43:fromUnits(100000,6)}});
 assert.deepEqual(clamped.plan,[['markets',43,90000]]);
 assert.equal(planRefills({...base,wanted:[{bot:'markets',asset:43}],held:{},headroom:{43:null}}).plan[0][2],500000,'no fuse, no clamp');
});

test('one refill per held asset, and unknown assets wait for a hand seed', () => {
 const {plan,skipped}=planRefills({...base,wanted:[{bot:'pools',asset:5},{bot:'pools',asset:1001},{bot:'replay',asset:4200},{bot:'markets',asset:34}],held:{}});
 assert.deepEqual(plan,[['pools',5,100000]]);
 assert.deepEqual(skipped.map(s=>[s.bot,s.asset]),[['replay',4200],['markets',34]]);
 assert.match(skipped[1].reason,/no cap for 34/);
});

test('refill rounds in the journal set the interval clock', () => {
 const last=lastRefills([
  {round:'20261008-a',plan:[{bot:'markets',asset:43,units:100000}]},
  {round:'refill-a',refill:true,at:at(0),plan:[{bot:'replay',asset:22,units:5,suppliedAs:1003},{bot:'markets',asset:43,units:1}]},
  {round:'refill-b',refill:true,at:at(30),plan:[{bot:'markets',asset:43,units:1}]},
 ]);
 assert.deepEqual(last,{'replay:1003':T0,'markets:43':T0+30*60000});
});

test('units survive the trip through the seed plan', () => {
 for(const [raw,d]of [[123456789n,6],[10n**18n/3n,18],[1n,10],[987654321012345678n,18]]){
  const back=fromUnits(toUnits(raw,d),d);
  assert.ok(back<=raw&&raw-back<10n**BigInt(Math.max(d-6,0)),`${raw}@${d}`);
 }
});
