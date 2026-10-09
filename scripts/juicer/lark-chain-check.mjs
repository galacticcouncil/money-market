// Read-only preflight for a new Lark: what the next version needs from the chain, recorded
// in the journal (ICE call indices included, so DcaDispatch's pinned encoding can be checked).
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,v,GOV,POOL,HOLLAR,token} from './lark-context.mjs';
const poolAbi=createRequire(import.meta.url)('../../deployments/hydration/Pool-Implementation.json').abi;
const ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760',RUNTIME=447,SYNTHETIC=5551;
const c=await context();
try{
 const {api,pub,r,save,readSig}=c,failures=[];
 const expect=(ok,message)=>{if(!ok)failures.push(message);};
 expect(r.runtime>=RUNTIME,`runtime ${r.runtime} predates ICE (${RUNTIME})`);
 const intent=api.tx.intent,ice=intent?.submitIntent&&intent.removeIntent&&intent.cleanupIntent&&api.tx.lazyExecutor?.dispatchTop;
 expect(ice,'ICE pallets (intent, lazyExecutor) missing');
 const reserves={};
 for(const [name,address]of [['ETH',token(34)],['TBTC',token(1000765)],['PRIME',token(43)],['HOLLAR',HOLLAR]]){
  reserves[name]=(await pub.readContract({address:POOL,abi:poolAbi,functionName:'getReserveData',args:[address]})).aTokenAddress;
  expect(reserves[name]!==v.zeroAddress,`no ${name} money-market reserve`);
 }
 const sources={};
 for(const id of [34,1000765,43]){
  sources[id]=await readSig(ORACLE,'function getSourceOfAsset(address) view returns(address)',[token(id)]);
  expect(sources[id]!==v.zeroAddress,`no MM oracle source for asset ${id}`);
 }
 const pool=(await api.query.stableswap.pools(143)).toJSON();
 expect([43,222].every(id=>pool?.assets.includes(id)),'stableswap pool 143 is not PRIME/HOLLAR');
 const route=(await api.query.router.routes([43,222])).toJSON();
 expect(JSON.stringify(route)===JSON.stringify([{pool:{stableswap:143},assetIn:43,assetOut:222}]),'stored PRIME/HOLLAR route does not use pool 143');
 expect((await api.query.assetRegistry.assets(SYNTHETIC)).isNone||!!r.addresses.synth,`asset id ${SYNTHETIC} is taken; the synthetic listing needs it`);
 const [capacity,level]=await readSig(HOLLAR,'function getFacilitator(address) view returns((uint128,uint128,string))',[GOV]);
 r.chainCheck={at:new Date().toISOString(),runtime:r.runtime,
  ice:ice?Object.fromEntries(['submitIntent','removeIntent','cleanupIntent'].map(name=>[name,Array.from(intent[name].callIndex)])):null,
  reserves,sources,pool143:pool,facilitator:{capacity:capacity.toString(),level:level.toString()},failures};
 r.checks.chain=failures.length===0;save();
 console.log('CHAIN',JSON.stringify(r.chainCheck));
 assert.equal(failures.length,0,failures.join('; '));
}finally{await c.api.disconnect();}
