import test from 'node:test';
import assert from 'node:assert/strict';
import {fairOutput,profitableQuote,freshReference,orientRoute,retainsQuoteInventory} from '../policy.mjs';
test('correction trades preserve inventory for both-direction live quotes',()=>{
 assert.equal(retainsQuoteInventory(5100n*10n**18n,5000n*10n**18n,100000000n,18),true);
 assert.equal(retainsQuoteInventory(5000n*10n**18n,5000n*10n**18n,100000000n,18),false);
 assert.equal(retainsQuoteInventory(100n*10n**6n,1n,106290112n,6),true);
 assert.equal(retainsQuoteInventory(90n*10n**6n,1n,106290112n,6),false);
});
test('PRIME NAV and token decimals govern the quote, not a 1:1 reserve ratio',()=>{
 assert.equal(fairOutput(1000000n,106290112n,100000000n,6,18),1062901120000000000n);
 assert.equal(fairOutput(1062901120000000000n,100000000n,106290112n,18,6),1000000n);
});
test('arbitrage minimum includes fees and never permits an oracle loss',()=>{
 assert.equal(profitableQuote({amount:100n,out:999n,fair:1000n}),null);
 assert.equal(profitableQuote({amount:100n,out:1000n,fair:1000n}),null);
 assert.equal(profitableQuote({amount:100n,out:1001n,fair:1000n}).minOut,1001n);
 assert.equal(profitableQuote({amount:100n,out:1100n,fair:1000n}).minOut,1099n);
});
test('stale, future or nonpositive canonical references cannot be refreshed',()=>{
 const good={price:1n,updatedAt:900n,chainTime:1000n,headAge:10,maxAge:200n};
 assert.equal(freshReference(good),true);
 for(const bad of [{price:0n},{updatedAt:0n},{updatedAt:1001n},{updatedAt:799n},{headAge:121},{headAge:-31}])assert.equal(freshReference({...good,...bad}),false);
});
test('stored routes reverse every hop without mutating the source',()=>{
 const route=[{pool:{stableswap:143},assetIn:43,assetOut:222},{pool:{omnipool:null},assetIn:222,assetOut:1000765}];
 assert.deepEqual(orientRoute(route,1000765,43),[{pool:{omnipool:null},assetIn:1000765,assetOut:222},{pool:{stableswap:143},assetIn:222,assetOut:43}]);
 assert.equal(route[0].assetIn,43);
 assert.throws(()=>orientRoute(route,34,43));
});

import {omnipoolRatio,omnipoolAfter,sizeOmnipoolTrade,deviationBps,correctionGainBps,replayTrades} from '../policy.mjs';
test('omnipool sizing moves the asset/anchor ratio onto the target from either side', () => {
 const asset={hub:1_000_000n*10n**12n,res:500_000n*10n**18n},anchor={hub:2_000_000n*10n**12n,res:2_000_000n*10n**18n};
 const ratio=omnipoolRatio(asset,anchor);
 for(const target of [ratio*99n/100n,ratio*101n/100n]){
  const {sellAsset,amount}=sizeOmnipoolTrade(asset,anchor,target,asset.res);
  assert.equal(sellAsset,target<ratio);
  const after=omnipoolAfter(asset,anchor,sellAsset,amount);
  assert.ok(deviationBps(after,target)<=1n&&deviationBps(after,target)>=-1n,`${after} vs ${target}`);
 }
 assert.equal(sizeOmnipoolTrade(asset,anchor,ratio/2n,10n**18n).amount,10n**18n,'capped at max');
});
test('a starved correction gains less than a funded one', () => {
 const asset={hub:1_000_000n*10n**12n,res:500_000n*10n**18n},anchor={hub:2_000_000n*10n**12n,res:2_000_000n*10n**18n};
 const target=omnipoolRatio(asset,anchor)*99n/100n,full=sizeOmnipoolTrade(asset,anchor,target,asset.res);
 assert.ok(correctionGainBps(asset,anchor,target,true,full.amount)>=99n);
 assert.ok(correctionGainBps(asset,anchor,target,true,10n**18n)<=1n);
 assert.equal(correctionGainBps(asset,anchor,target,true,0n),0n);
});
test('replay keeps top-level routed trades and drops their inner pool legs', () => {
 const trades=replayTrades([
  [{name:'omnipool.SellExecuted',input:5,output:0,amount:10n},{name:'router.Executed',input:5,output:222,amount:10n}],
  [{name:'stableswap.SellExecuted',pool:100,input:10,output:22,amount:7n}],
  [{name:'xyk.BuyExecuted',input:0,output:30,amount:0n}],
 ]);
 assert.deepEqual(trades.map(t=>[t.input,t.output,t.amount]),[[5,222,10n],[10,22,7n]]);
 assert.deepEqual(trades[1].route,[{pool:{Stableswap:100},assetIn:10,assetOut:22}]);
});
