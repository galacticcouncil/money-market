// Lark only: the SubLoop's entries and routine exits go through ICE intents. lark-ice-plan.mjs
// says what is missing: intent ttl and drift, KEEPER_ROLE for both keepers, async controller
// lanes, and WETH plus a little HDX on the loop's mapped account so the lazy-executor callback
// fee is paid in WETH, never HOLLAR. One referendum; keeper reconcile covers a missed callback.
import assert from 'node:assert/strict';
import {context,v,live} from './lark-context.mjs';
import {ICE,WETH,LOOP_ABI,CONTROLLER_ABI,icePlan} from './lark-ice-plan.mjs';
const loopAbi=v.parseAbi(LOOP_ABI),controllerAbi=v.parseAbi(CONTROLLER_ABI);
const c=await context();
try{
 const {api,pub,r,save,govEvm,enact}=c,source=r.addresses.source,controller=r.addresses.controller;
 assert.ok(r.governance.find(g=>g.label==='bind-execution-controller')?.verified,'finish core wiring first');
 const read=(address,abi,functionName,args=[])=>pub.readContract({address,abi,functionName,args});
 const keepers=[r.testSigners.keeper,r.testSigners.keeperSecondary];
 const lanes=r.executionPolicy.limits.filter(l=>l.consumer.toLowerCase()===source.toLowerCase());
 assert.equal(lanes.length,2,'the source needs its entry and unwind lanes');
 const account=await c.nativeAccount(source),role=await read(source,loopAbi,'KEEPER_ROLE');
 const state=async()=>({
  intentTtl:await read(source,loopAbi,'intentTtl'),intentDriftBps:await read(source,loopAbi,'intentDriftBps'),
  keepers:await Promise.all(keepers.map(async address=>({address,hasRole:!!address&&await read(source,loopAbi,'hasRole',[role,address])}))),
  lanes:await Promise.all(lanes.map(async l=>({name:l.input.toLowerCase()===r.market.aPrime.toLowerCase()?'unwind':'entry',lane:l.lane,
   maximum:(await read(controller,controllerAbi,'limits',[l.lane]))[2],async:await read(controller,controllerAbi,'asyncLanes',[l.lane])}))),
  feeCurrency:(await api.query.multiTransactionPayment.accountCurrencyMap(account)).unwrapOr(null)?.toNumber()??null,
  weth:(await api.call.currenciesApi.account(WETH,account)).free.toBigInt(),
  hdx:(await api.query.system.account(account)).data.free.toBigInt(),
 });
 const actions=icePlan(await state());
 console.log('ICE',JSON.stringify(actions,(_,x)=>typeof x==='bigint'?x.toString():x));
 const weth=actions.find(a=>a.kind==='weth');
 if(weth){const room=await c.fuseHeadroom(WETH);assert.ok(room===null||weth.amount<=room,`WETH ${weth.amount} would trip the deposit fuse (${room} left)`);}
 const call={
  intents:a=>govEvm(source,loopAbi,'configureIntents',[a.ttl,a.driftBps],500000),
  keeper:a=>govEvm(source,loopAbi,'grantRole',[role,a.keeper],500000),
  async:a=>govEvm(controller,controllerAbi,'configureAsync',[a.lane,true],500000),
  'fee-currency':()=>api.tx.multiTransactionPayment.resetPaymentCurrency(account),
  hdx:a=>api.tx.currencies.updateBalance(account,0,a.amount.toString()),
  weth:a=>api.tx.currencies.updateBalance(account,WETH,a.amount.toString()),
 };
 if(actions.length)await enact('ice-wiring',actions.map(a=>call[a.kind](a)));
 if(live){
  assert.deepEqual(icePlan(await state()),[],'ice wiring incomplete after enactment');
  r.checks.iceWiring={ttlSeconds:ICE.ttl,driftBps:ICE.driftBps,keepers,lanes:lanes.map(l=>l.lane),feeCurrency:WETH,account};save();
  console.log('ICE WIRED',JSON.stringify(r.checks.iceWiring));
 }
}finally{await c.api.disconnect();}
