import test from 'node:test';
import assert from 'node:assert/strict';
import {fairOutput,pegPremium,sizeToTarget,pegMinOut,pegEdge,arbTrade,freshReference,quotePairs,orientRoute,omnipoolRatio,omnipoolAfter,sizeOmnipoolTrade,deviationBps,correctionGainBps,replayTrades,swapRoute,depositOwed,userDeposit,botIdentity,depositStop,depositBlock} from '../policy.mjs';
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
 const down=await sizeToTarget(linear(567n,1n),567n,10000n);
 assert.ok(down<=567n&&down>=567n-10000n/1024n,'a premium is sold down to the oracle within one step');
 assert.equal(await sizeToTarget(linear(567n,1n),567n,100n),100n,'a short cap corrects partially');
 const up=await sizeToTarget(async a=>-300n+a*3n,-300n,1024n);
 assert.ok(up<=100n&&up>=99n,'a discount is bought back from below');
 assert.equal(await sizeToTarget(linear(0n,1n),0n,1000n),0n);
});
test('a peg trade pays at most the loss cap under the oracle',()=>{
 assert.equal(pegMinOut({out:9994n,fair:10000n}),null);
 assert.equal(pegMinOut({out:9996n,fair:10000n}),9995n);
 assert.equal(pegMinOut({out:10100n,fair:10000n}),10097n);
});
test('a fill\'s edge over the oracle comes in 1/100 bps, negative when it falls short',()=>{
 assert.equal(pegEdge(1001467n,1000000n),1467n);
 assert.equal(pegEdge(997735n,1000000n),-2265n);
 assert.throws(()=>pegEdge(1n,0n));
});
test('a profit-seeking peg trade never fills under the oracle plus its profit',()=>{
 assert.equal(pegMinOut({out:10000n,fair:10000n,minProfitCbps:0n}),10000n);
 assert.equal(pegMinOut({out:9999n,fair:10000n,minProfitCbps:0n}),null);
 assert.equal(pegMinOut({out:10012n,fair:10000n,minProfitCbps:1000n}),10010n);
 assert.equal(pegMinOut({out:10009n,fair:10000n,minProfitCbps:1000n}),null);
 assert.equal(pegMinOut({out:10100n,fair:10000n,minProfitCbps:0n}),10097n,'quote drift still applies above the floor');
 assert.equal(pegMinOut({out:10000n,fair:10000n,minProfitCbps:-1n}),null);
});
test('a profit-seeking arb trades only past its profit, and only as far as the next probe stays there',async()=>{
 const rich=async(id,a)=>id===43?1467n-a:-2265n,none=()=>0n;
 const t=await arbTrade({edgeAfter:rich,inputs:[43,222],max:()=>100000n,minProfit:none});
 assert.deepEqual([t.input,t.before,t.edges],[43,1467n,[1467n,-2265n]]);
 assert.ok(t.amount<=1467n&&t.amount>=1467n-100000n/1024n,'it sells until the next probe breaks even');
 assert.deepEqual(await arbTrade({edgeAfter:rich,inputs:[43,222],max:()=>100000n,minProfit:()=>1500n}),{edges:[1467n,-2265n]},'short of its profit it stays out');
 assert.equal((await arbTrade({edgeAfter:rich,inputs:[43,222],max:()=>100n,minProfit:none})).amount,100n,'inventory caps the sale');
 const cheap=await arbTrade({edgeAfter:async(id,a)=>id===222?250n-a:-1050n,inputs:[43,222],max:()=>1000n,minProfit:()=>100n});
 assert.deepEqual([cheap.input,cheap.amount],[222,150n],'a cheap pool is bought back to the fee plus the profit');
 assert.equal((await arbTrade({edgeAfter:async()=>0n,inputs:[43,222],max:()=>1000n,minProfit:none})).amount,0n,'at the band edge there is nothing left to take');
});
test('each side keeps its own profit: mainnet leaves a rich pool alone longer than a cheap one',async()=>{
 const mainnet=id=>id===43?1500n:400n;
 assert.deepEqual(await arbTrade({edgeAfter:async(id,a)=>id===43?1470n-a:-2270n,inputs:[43,222],max:()=>100000n,minProfit:mainnet}),{edges:[1470n,-2270n]},'14.7 bps over the oracle is not enough to sell');
 const cheap=await arbTrade({edgeAfter:async(id,a)=>id===222?500n-a:-1300n,inputs:[43,222],max:()=>1000n,minProfit:mainnet});
 assert.deepEqual([cheap.input,cheap.amount],[222,100n],'5 bps is enough to buy, down to 4');
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
test('the manifest names the chain and signers; a lark 4 manifest keeps today\'s', () => {
 assert.deepEqual(botIdentity({genesis:'0x01'}),{chainName:'Lark 4 Hydration',signers:{markets:'//Alice//propeller-20261005-arb',pools:'//Alice//propeller-20261007-pools',replay:'//Alice//propeller-20261007-replay'}});
 const next=botIdentity({chainName:'Lark 7 Hydration',signers:{pools:'//Alice//p'}});
 assert.equal(next.chainName,'Lark 7 Hydration');
 assert.equal(next.signers.pools,'//Alice//p');
 assert.equal(next.signers.markets,'//Alice//propeller-20261005-arb');
 assert.throws(()=>botIdentity({chainName:'Hydration'}),/not a lark chain/);
});
test('deposits read the keepers\' deficit stop on new vaults and isUnderfunded on lark 4', async () => {
 const vault=views=>async f=>{if(!(f in views))throw Error('execution reverted');return views[f];};
 assert.deepEqual(await depositStop(vault({deficitStop:true})),{deficitStop:true,underfunded:false});
 assert.deepEqual(await depositStop(vault({deficitStop:false})),{deficitStop:false,underfunded:false});
 assert.deepEqual(await depositStop(vault({isUnderfunded:true})),{deficitStop:false,underfunded:true});
 await assert.rejects(depositStop(vault({})),/reverted/,'a vault answering neither is never cleared');
 const open={paused:false,depositsPaused:false,deficitStop:false,underfunded:false,assets:1n,size:1n,cap:10n};
 assert.equal(depositBlock(open),null);
 assert.equal(depositBlock({...open,deficitStop:true}),'deficit-stop');
 assert.equal(depositBlock({...open,depositsPaused:true,deficitStop:true}),'deposits-paused');
 assert.equal(depositBlock({...open,underfunded:true}),'underfunded');
 assert.equal(depositBlock({...open,size:10n}),'tvl-cap');
});
test('markets quotes each vault collateral against HOLLAR and PRIME, lark 4 and 0 as before', () => {
 assert.deepEqual(quotePairs([34,1000765]),[[43,222],[34,222],[222,1000765],[34,43],[43,1000765]]);
 assert.deepEqual(quotePairs([4200,1000765]),[[43,222],[222,4200],[222,1000765],[43,4200],[43,1000765]],'GIGAETH behind jETH');
 assert.deepEqual(quotePairs([]),[[43,222]]);
});
