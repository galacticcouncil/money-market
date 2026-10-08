// Lark only: test inventory for the market bots, sized from what their logs say
// they lacked. Token-type assets are minted within each deposit fuse; aTokens are
// supplied from minted underlying as the bot itself (dispatchAs), so nothing races
// a live bot's nonce. One referendum per --round; every amount lands in the journal.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const round=process.argv.find(a=>a.startsWith('--round='))?.split('=')[1];
assert.ok(round,'usage: --round=<name> [--live]');
const SIGNERS=profile.signers;
const u=(n,d)=>BigInt(Math.round(n*1e6))*10n**BigInt(d)/1000000n;
// [bot, asset, units to mint, aToken to supply it into (optional)]
const PLANS={
 '20261008-a':[
  ['replay',22,300000,1003],['replay',10,150000,1002],['replay',1000765,0.5,1006],['replay',5,20000],['replay',5,20000,1001],
  ['replay',38,20000],['replay',35,5000],
  ['pools',22,50000],
  ['markets',43,100000],
 ],
 // the loop's ramp plus replayed mainnet PRIME buys outrun PRIME's fuse window
 '20261008-b':[['markets',43,300000]],
};
// lark-only deposit fuse raises (units per window), applied before the mints
const RAISES={'20261008-b':[[43,5000000]]};
// a new lark starts with everything the lark 4 bots reported missing
PLANS.baseline=[...PLANS['20261008-a'],...PLANS['20261008-b']];RAISES.baseline=RAISES['20261008-b'];
const plan=PLANS[round];
assert.ok(plan,`unknown round ${round}`);
const c=await context();
try{
 const {api,r,enact,save}=c;
 const label=`bots-seed-${round}`,who=bot=>new Keyring({type:'sr25519'}).addFromUri(SIGNERS[bot]).address;
 const decimals={},minted={};
 for(const [,id,n] of plan){
  decimals[id]??=Number((await api.query.assetRegistry.assets(id)).unwrap().decimals.toString());
  minted[id]=(minted[id]??0n)+u(n,decimals[id]);
 }
 if(!r.governance.find(g=>g.label===label)?.verified)for(const [id,amount] of Object.entries(minted)){
  const raised=(RAISES[round]??[]).find(([x])=>x===Number(id));
  const limit=raised?u(raised[1],decimals[id]):(await api.query.assetRegistry.assets(id)).unwrap().xcmRateLimit.unwrapOr(null)?.toBigInt();
  const state=(await api.query.circuitBreaker.assetLockdownState(id)).unwrapOr(null);
  if(limit===undefined||!state)continue;
  assert.ok(state.isUnlocked,`${id} is in lockdown`);
  const used=(await api.query.tokens.totalIssuance(id)).toBigInt()-state.asUnlocked[1].toBigInt();
  assert.ok(amount<=limit-used,`${id}: ${amount} would trip the deposit fuse (${limit-used} left)`);
 }
 const calls=(RAISES[round]??[]).map(([id,n])=>api.tx.assetRegistry.update(id,null,null,null,u(n,decimals[id]).toString(),null,null,null,null)),wraps=[];
 for(const [bot,id,n,aToken] of plan){
  const amount=u(n,decimals[id]);
  calls.push(api.tx.currencies.updateBalance(who(bot),id,amount.toString()));
  if(aToken)wraps.push(api.tx.utility.dispatchAs({system:{Signed:who(bot)}},
   api.tx.router.sell(id,aToken,amount.toString(),(amount*99n/100n).toString(),[{pool:'Aave',assetIn:id,assetOut:aToken}])));
 }
 calls.push(...wraps);
 // dispatchAs reports an inner failure as an event, not a failed batch
 const dry=await api.call.dryRunApi.dryRunCall({system:'Root'},api.tx.utility.batchAll(calls),4);
 assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`${label}: dry run failed`);
 const dispatched=dry.asOk.emittedEvents.filter(e=>e.section==='utility'&&e.method==='DispatchedAs');
 assert.equal(dispatched.length,wraps.length);
 for(const e of dispatched)assert.ok(e.data[0].isOk,`${label}: a supply fails: ${e.data[0]}`);
 await enact(label,calls);
 if(live){
  r.testSeeds??=[];
  if(!r.testSeeds.some(s=>s.round===round))r.testSeeds.push({round,...(RAISES[round]?{fuseRaises:RAISES[round].map(([asset,units])=>({asset,units}))}:{}),plan:plan.map(([bot,id,n,aToken])=>({bot,asset:id,units:n,...(aToken?{suppliedAs:aToken}:{})})),ref:r.governance.find(g=>g.label===label)?.ref,note:'test inventory; spent only by market simulation'});
  save();
  for(const [bot,id] of plan)assert.equal((await api.query.tokens.accounts(who(bot),id)).reserved.toBigInt(),0n,`${id} parked by the fuse`);
  for(const [bot,id,,aToken] of plan){
   const held=(await api.call.currenciesApi.account(aToken??id,who(bot))).free.toString();
   console.log('HELD',bot,aToken??id,held);
  }
 }
}finally{await c.api.disconnect();}
