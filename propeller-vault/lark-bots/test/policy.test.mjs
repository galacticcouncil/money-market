import test from 'node:test';
import assert from 'node:assert/strict';
import {fairOutput,pegPremium,sizePeg,pegMinOut,freshReference,orientRoute,omnipoolRatio,omnipoolAfter,sizeOmnipoolTrade,deviationBps,correctionGainBps,replayTrades,swapRoute,depositOwed,userDeposit} from '../policy.mjs';
test('PRIME NAV and token decimals govern the quote, not a 1:1 reserve ratio',()=>{
 assert.equal(fairOutput(1000000n,106290112n,100000000n,6,18),1062901120000000000n);
 assert.equal(fairOutput(1062901120000000000n,100000000n,106290112n,18,6),1000000n);
});
test('the peg premium cancels the pool fee from both probe directions',()=>{
 // lark pool 143: buying costs 9.68 bps, selling earns 1.67 bps -> 5.67 bps rich
 assert.equal(pegPremium({buyOut:999032n,buyFair:1000000n,sellOut:1000167n,sellFair:1000000n}),567n);
 assert.equal(pegPremium({buyOut:999600n,buyFair:1000000n,sellOut:999600n,sellFair:1000000n}),0n);
 assert.equal(pegPremium({buyOut:999900n,buyFair:1000000n,sellOut:999300n,sellFair:1000000n}),-300n);
});
test('peg sizing stops at the oracle, never past it',async()=>{
 const linear=(before,perUnit)=>async a=>before-a*perUnit;
 const down=await sizePeg(linear(567n,1n),567n,10000n);
 assert.ok(down<=567n&&down>=567n-10000n/1024n,'a premium is sold down to the oracle within one step');
 assert.equal(await sizePeg(linear(567n,1n),567n,100n),100n,'a short cap corrects partially');
 const up=await sizePeg(async a=>-300n+a*3n,-300n,1024n);
 assert.ok(up<=100n&&up>=99n,'a discount is bought back from below');
 assert.equal(await sizePeg(linear(0n,1n),0n,1000n),0n);
});
test('a peg trade pays at most the loss cap under the oracle',()=>{
 assert.equal(pegMinOut({out:9994n,fair:10000n}),null);
 assert.equal(pegMinOut({out:9996n,fair:10000n}),9995n);
 assert.equal(pegMinOut({out:10100n,fair:10000n}),10097n);
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
test('replay rebuilds routed trades from their swap legs', () => {
 const leg=(filler,input,output)=>({name:'broadcast.Swapped3',filler,input,output});
 const [t]=replayTrades([[
  {name:'omnipool.SellExecuted',input:1000796,output:222,amount:5n},
  leg('Omnipool',1000796,1),leg('Omnipool',1,222),leg({Stableswap:111},222,1002),leg('AAVE',1002,10),
  {name:'router.Executed',input:1000796,output:10,amount:5n},
 ]]);
 assert.deepEqual(t.route,[{pool:'Omnipool',assetIn:1000796,assetOut:222},{pool:{Stableswap:111},assetIn:222,assetOut:1002},{pool:'Aave',assetIn:1002,assetOut:10}]);
 assert.equal(swapRoute([leg('AAVE',5,1001),leg('UniswapV3',1001,222)],5,222),null,'uniswap v3 hops carry no pool id');
 assert.equal(swapRoute([leg('AAVE',5,1001)],5,222),null,'route must reach the output');
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
test('user-like deposits draw random sizes but track the schedule', () => {
 const total=144n*10n**18n,start=1000n,duration=144n*1800n,slot=10n**18n;
 const owed=(now,remaining=total)=>depositOwed({total,remaining,start,duration,now});
 assert.equal(owed(start),0n);
 assert.equal(owed(start+1800n),slot,'one slot per period');
 assert.equal(owed(start+2n*duration,0n),0n,'fully deposited');
 assert.equal(userDeposit({owed:slot,slot,rand:()=>0}),slot/5n,'smallest draw is a fifth of a slot');
 assert.equal(userDeposit({owed:slot,slot,rand:()=>1}),2n*slot,'big draws stop one slot ahead of schedule');
 assert.equal(userDeposit({owed:100n*slot,slot,rand:()=>1}),5n*slot,'catch-up is still one user-sized deposit');
 assert.equal(userDeposit({owed:-slot,slot,rand:()=>1}),0n,'a slot ahead waits');
 assert.equal(userDeposit({owed:-slot+slot/20n,slot,rand:()=>1}),0n,'dust is skipped');
});
