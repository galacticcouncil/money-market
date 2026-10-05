import test from 'node:test';
import assert from 'node:assert/strict';
import {fairOutput,profitableQuote,freshReference,orientRoute} from '../policy.mjs';
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
