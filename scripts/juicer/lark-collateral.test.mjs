import test from 'node:test';
import assert from 'node:assert/strict';
import {buyMax,buyCall,fundCalls,recordBuy,checkBuys,assertBought,primeRoute,BUY_SLACK_BPS} from './lark-collateral.mjs';
import {resolveProfile} from './lark-pins.mjs';
const GIGAETH=resolveProfile('next',{LARK_DEPLOYMENT:'next-test'}).collateral.ETH,TBTC=resolveProfile('lark0',{}).collateral.TBTC;
// mainnet on 13 october: oracle prices, and the ETH a dry-run exact-out buy of 1 GIGAETH spent
const MAINNET={priceIn:250670728119n,priceOut:254967164237n,decimalsIn:18,decimalsOut:18},SPENT=1017193365164983298n;
const tx=name=>(...args)=>({name,args});
const api={tx:{currencies:{updateBalance:tx('currencies.updateBalance')},utility:{dispatchAs:tx('utility.dispatchAs'),batchAll:tx('utility.batchAll')},router:{buy:tx('router.buy')}}};

test('a buy may spend the oracle-fair input plus 1%, rounded up, across decimals', () => {
 const max=buyMax(10n**18n,MAINNET);
 assert.equal(BUY_SLACK_BPS,100n);
 assert.equal(max,1027311157596031605n);
 assert.ok(max*10000n*MAINNET.priceIn>=10n**18n*MAINNET.priceOut*10100n,'at least 1% over oracle-fair');
 assert.ok(SPENT<=max,'the pool path costs well under the slack');
 assert.equal(buyMax(10n**6n,{priceIn:2n,priceOut:1n,decimalsIn:18,decimalsOut:6},0n),5n*10n**17n,'1 unit of a 6-decimal asset at half the input price');
 assert.equal(buyMax(1n,{priceIn:3n,priceOut:1n,decimalsIn:0,decimalsOut:0},0n),1n,'rounds up');
});

test('a token is minted; GIGAETH is bought with minted ETH through Aave and pool 4200, never minted', () => {
 assert.deepEqual(fundCalls(api,'who',TBTC,'5'),[{name:'currencies.updateBalance',args:['who',1000765,'5']}]);
 const calls=fundCalls(api,'who',GIGAETH,10n**18n,1027311157596031605n);
 assert.deepEqual(calls[0],{name:'currencies.updateBalance',args:['who',34,'1027311157596031605']});
 assert.deepEqual(calls[1],{name:'utility.dispatchAs',args:[{system:{Signed:'who'}},{name:'router.buy',args:[34,4200,'1000000000000000000','1027311157596031605',
  [{pool:'Aave',assetIn:34,assetOut:1007},{pool:{Stableswap:4200},assetIn:1007,assetOut:4200}]]}]});
 assert.deepEqual(buyCall(api,'who',GIGAETH,'1','2'),{name:'utility.dispatchAs',args:[{system:{Signed:'who'}},{name:'router.buy',args:[34,4200,'1','2',GIGAETH.buy.route]}]});
 assert.ok(!calls.some(c=>c.name==='currencies.updateBalance'&&c.args[1]===4200),'no share is minted');
});

test('a buy is priced once and journaled, so a resumed referendum keeps its payload', async () => {
 let reads=0,saves=0;
 const c={r:{},save:()=>saves++,api:{query:{assetRegistry:{assets:async()=>({unwrap:()=>({decimals:18})})}}},
  readSig:async(oracle,sig,[address])=>{reads++;return address.endsWith('1068')?MAINNET.priceOut:MAINNET.priceIn;}};
 const b=await recordBuy(c,GIGAETH,'deployer',10n**18n);
 assert.deepEqual(b,{name:'deployer',assetId:4200,from:34,amount:'1000000000000000000',max:buyMax(10n**18n,MAINNET).toString()});
 assert.equal(await recordBuy(c,GIGAETH,'deployer',10n**18n),b);
 assert.deepEqual([reads,saves,c.r.testBuys.length],[2,1,1]);
});

test('a failed, missing or fuse-tripping buy stops the step before its referendum', async () => {
 const dispatched=results=>({isOk:true,asOk:{executionResult:{isOk:true},emittedEvents:results.map(isOk=>({section:'utility',method:'DispatchedAs',data:[{isOk,toString:()=>isOk?'Ok':'Err'}]}))}});
 const ctx=(results,room=null,governance=[])=>({r:{governance},fuseHeadroom:async()=>room,api:{tx:api.tx,call:{dryRunApi:{dryRunCall:async()=>dispatched(results)}}}});
 await checkBuys(ctx([true,true]),'x',[],2,{collateral:GIGAETH,amount:5n});
 await checkBuys(ctx([true],5n),'x',[],1,{collateral:GIGAETH,amount:5n});
 await assert.rejects(checkBuys(ctx([true],4n),'x',[],1,{collateral:GIGAETH,amount:5n}),/deposit fuse/);
 await checkBuys(ctx([true],0n),'x',[],1);
 await assert.rejects(checkBuys(ctx([true,false]),'x',[],2),/a buy fails/);
 await assert.rejects(checkBuys(ctx([true]),'x',[],2),/expected 2 buys/);
 await checkBuys(ctx([false],0n,[{label:'x',verified:true}]),'x',[],2,{collateral:GIGAETH,amount:5n});
});

test('enacted buys are read back from the journaled events', () => {
 const r=events=>({governance:[{label:'x',enactment:{events}}]}),as=data=>({section:'utility',method:'DispatchedAs',data:[data]});
 assertBought(r([as({ok:null}),{section:'currencies',method:'BalanceUpdated',data:[]}]),'x');
 assert.throws(()=>assertBought(r([as({ok:null}),as({err:{module:{index:67,error:'0x01000000'}}})]),'x'),/enacted buy failed/);
 assert.throws(()=>assertBought({governance:[{label:'x'}]},'x'),/not enacted/);
});

test('PRIME routes compose from mainnet\'s stored legs: lark 0 as before, GIGAETH through aGETH', () => {
 const prime=[{pool:{stableswap:143},assetIn:43,assetOut:222}];
 const eth=[{pool:{aave:null},assetIn:34,assetOut:1007},{pool:{stableswap:4200},assetIn:1007,assetOut:4200},{pool:{aave:null},assetIn:4200,assetOut:420},{pool:{omnipool:null},assetIn:420,assetOut:222}];
 const btc=[{pool:{omnipool:null},assetIn:222,assetOut:1000765}],giga=[{pool:{omnipool:null},assetIn:222,assetOut:420},{pool:{aave:null},assetIn:420,assetOut:4200}];
 assert.deepEqual(primeRoute(34,prime,eth),[{assetIn:34,assetOut:43},[...eth,{pool:{stableswap:143},assetIn:222,assetOut:43}]]);
 assert.deepEqual(primeRoute(1000765,prime,btc),[{assetIn:43,assetOut:1000765},[...prime,...btc]]);
 assert.deepEqual(primeRoute(4200,prime,giga),[{assetIn:43,assetOut:4200},[...prime,...giga]]);
 const [pair,route]=primeRoute(100,prime,[{pool:{omnipool:null},assetIn:100,assetOut:222}]);
 assert.deepEqual([pair,route.at(-1)],[{assetIn:43,assetOut:100},{pool:{omnipool:null},assetIn:222,assetOut:100}],'a leg stored toward HOLLAR is reversed');
});
