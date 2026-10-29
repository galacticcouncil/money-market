// A fresh mainnet fork has no stored PRIME<->collateral routes, so harvest swaps fall
// back to a direct omnipool hop that PRIME is not in. Compose them from stored legs.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
import {primeRoute} from './lark-collateral.mjs';
const c=await context();
try{
 const {api,r,save}=c;
 const stored=async(a,b)=>(await api.query.router.routes([Math.min(a,b),Math.max(a,b)])).toJSON();
 const prime=await stored(43,222);assert.deepEqual(prime,[{pool:{stableswap:143},assetIn:43,assetOut:222}]);
 const routes=[];
 for(const {assetId:id,symbol}of Object.values(profile.collateral)){
  const leg=await stored(id,222);assert.ok(leg,`stored ${symbol}/HOLLAR leg missing`);
  routes.push(primeRoute(id,prime,leg));
 }
 const calls=[];
 for(const [pair,route]of routes)if(!(await stored(pair.assetIn,pair.assetOut)))calls.push(api.tx.router.forceInsertRoute(pair,route));
 r.routes=routes.map(([pair,route])=>({pair,route}));save();
 if(calls.length)await c.enact('store-prime-collateral-routes',calls);
 if(live){for(const [pair]of routes)assert.ok(await stored(pair.assetIn,pair.assetOut));r.checks.primeCollateralRoutes=true;save();console.log('ROUTES STORED');}
}finally{await c.api.disconnect();}
