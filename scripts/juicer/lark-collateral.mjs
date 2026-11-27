// Test collateral for a profile's vaults (lark-pins.mjs), and PRIME's routes to it. A token is
// minted to its holder; a pool share (GIGAETH) is bought through the router as its holder, paid
// in the token it names, as users get it. The buy is exact-out: a holder gets the planned amount.
import assert from 'node:assert/strict';
const ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
const token=id=>`0x${(0x100000000n+BigInt(id)).toString(16).padStart(40,'0')}`;
// what a buy may spend over the oracle-fair input: fees, pool skew and drift
export const BUY_SLACK_BPS=100n;
export function buyMax(amount,{priceIn,priceOut,decimalsIn,decimalsOut},slackBps=BUY_SLACK_BPS){
 const num=BigInt(amount)*priceOut*10n**BigInt(decimalsIn)*(10000n+slackBps),den=priceIn*10n**BigInt(decimalsOut)*10000n;
 return (num+den-1n)/den;
}
export function buyCall(api,who,collateral,amount,max){
 const {from,route}=collateral.buy;
 return api.tx.utility.dispatchAs({system:{Signed:who}},api.tx.router.buy(from,collateral.assetId,amount.toString(),max.toString(),route));
}
// `who` ends up with `amount` more collateral: minted, or bought with `max` of minted input
export function fundCalls(api,who,collateral,amount,max){
 if(!collateral.buy)return [api.tx.currencies.updateBalance(who,collateral.assetId,amount.toString())];
 return [api.tx.currencies.updateBalance(who,collateral.buy.from,max.toString()),buyCall(api,who,collateral,amount,max)];
}
// MM oracle prices and registry decimals of a buy's input and output, on the chain c connects to
export async function buyQuote(c,collateral){
 const ids=[collateral.buy.from,collateral.assetId];
 const [priceIn,priceOut]=await Promise.all(ids.map(id=>c.readSig(ORACLE,'function getAssetPrice(address) view returns(uint256)',[token(id)])));
 const [decimalsIn,decimalsOut]=await Promise.all(ids.map(async id=>Number((await c.api.query.assetRegistry.assets(id)).unwrap().decimals.toString())));
 return {priceIn,priceOut,decimalsIn,decimalsOut};
}
// priced once and journaled: a resumed referendum must carry the payload it was dry-run with
export async function recordBuy(c,collateral,name,amount){
 c.r.testBuys??=[];
 let b=c.r.testBuys.find(x=>x.name===name&&x.assetId===collateral.assetId);
 if(!b){b={name,assetId:collateral.assetId,from:collateral.buy.from,amount:amount.toString(),max:buyMax(amount,await buyQuote(c,collateral)).toString()};c.r.testBuys.push(b);c.save();}
 return b;
}
// dispatchAs reports a failed buy as an event, not a failed batch, and a share minted past its
// deposit fuse is parked; `fuse` is left out when the batch raises that fuse itself
export async function checkBuys(c,label,calls,count,fuse){
 if(c.r.governance.find(g=>g.label===label)?.verified)return;
 if(fuse){
  const room=await c.fuseHeadroom(fuse.collateral.assetId);
  assert.ok(room===null||BigInt(fuse.amount)<=room,`${label}: buying ${fuse.amount} ${fuse.collateral.symbol} would trip its deposit fuse (${room} left)`);
 }
 const dry=await c.api.call.dryRunApi.dryRunCall({system:'Root'},c.api.tx.utility.batchAll(calls),4);
 assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`${label}: dry run failed`);
 const bought=dry.asOk.emittedEvents.filter(e=>e.section==='utility'&&e.method==='DispatchedAs');
 assert.equal(bought.length,count,`${label}: expected ${count} buys`);
 for(const e of bought)assert.ok(e.data[0].isOk,`${label}: a buy fails: ${e.data[0]}`);
}
// the same, from the events the enacted referendum journaled
export function assertBought(r,label){
 const events=r.governance.find(g=>g.label===label)?.enactment?.events;
 assert.ok(events,`${label}: not enacted`);
 const failed=events.filter(e=>e.section==='utility'&&e.method==='DispatchedAs'&&!('ok' in (e.data?.[0]??{})));
 assert.equal(failed.length,0,`${label}: an enacted buy failed: ${JSON.stringify(failed)}`);
}
const reverse=route=>route.slice().reverse().map(t=>({pool:t.pool,assetIn:t.assetOut,assetOut:t.assetIn}));
// the pair and route between PRIME (43) and a collateral, from the stored PRIME -> HOLLAR route
// and the collateral's stored HOLLAR leg; the router keys a pair, and its route, from the lower id
export function primeRoute(id,prime,leg){
 return id<43?[{assetIn:id,assetOut:43},[...leg,...reverse(prime)]]:[{assetIn:43,assetOut:id},[...prime,...(id<222?reverse(leg):leg)]];
}
