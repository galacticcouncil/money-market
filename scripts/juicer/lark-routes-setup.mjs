// A fresh mainnet fork has no stored PRIME<->ETH/tBTC routes, so harvest swaps fall
// back to a direct omnipool hop that PRIME is not in. Compose them from stored legs.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
const c=await context();
try{
 const {api,r,save}=c;
 const stored=async(a,b)=>(await api.query.router.routes([Math.min(a,b),Math.max(a,b)])).toJSON();
 const prime=await stored(43,222);assert.deepEqual(prime,[{pool:{stableswap:143},assetIn:43,assetOut:222}]);
 const eth=await stored(34,222),btc=await stored(222,1000765);assert.ok(eth&&btc,'stored HOLLAR legs missing');
 const reverse=route=>route.slice().reverse().map(t=>({pool:t.pool,assetIn:t.assetOut,assetOut:t.assetIn}));
 const routes=[
  [{assetIn:34,assetOut:43},[...eth,...reverse(prime)]],
  [{assetIn:43,assetOut:1000765},[...prime,...btc]],
 ];
 const calls=[];
 for(const [pair,route]of routes)if(!(await stored(pair.assetIn,pair.assetOut)))calls.push(api.tx.router.forceInsertRoute(pair,route));
 r.routes=routes.map(([pair,route])=>({pair,route}));save();
 if(calls.length)await c.enact('store-prime-collateral-routes',calls);
 if(live){for(const [pair]of routes)assert.ok(await stored(pair.assetIn,pair.assetOut));r.checks.primeCollateralRoutes=true;save();console.log('ROUTES STORED');}
}finally{await c.api.disconnect();}
