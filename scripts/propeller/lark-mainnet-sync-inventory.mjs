// Long-tail replay inventory and EVM-token inventory bought with test HOLLAR.
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const c=await context();
try{
 const {api,r,save,enact,sign}=c;
 const kr=new Keyring({type:'sr25519'}),pools=kr.addFromUri(profile.signers.pools),replay=kr.addFromUri(profile.signers.replay);
 const xyk=new Set();for(const [,v]of await api.query.xyk.poolAssets.entries())for(const a of v.unwrap())xyk.add(a.toNumber());
 const funded=new Set(r.mainnetSync.funding.filter(f=>f.who===replay.address).map(f=>f.id));
 const calls=[];
 for(const id of xyk){
  if(id===1||funded.has(id))continue;
  const meta=await api.query.assetRegistry.assets(id);if(meta.isNone||meta.unwrap().assetType.toString()!=='Token')continue;
  const issuance=BigInt((await api.query.tokens.totalIssuance(id)).toString());if(issuance===0n)continue;
  calls.push([id,issuance/100n]);
 }
 const btc=BigInt((await api.query.tokens.totalIssuance(1000765)).toString())/20n;calls.push([1000765,btc]);
 r.mainnetSync.longTail=calls.map(([id,amount])=>({id,amount:amount.toString()}));save();
 await enact('fund-replay-long-tail',calls.map(([id,amount])=>api.tx.currencies.updateBalance(replay.address,id,amount.toString())));
 // EVM-token omnipool assets cannot be minted; buy a small working inventory
 for(const [name,pair]of [['pools',pools],['replay',replay]])for(const id of [420,1001,9001]){
  if(BigInt((await api.call.currenciesApi.account(id,pair.address)).free.toString())>0n)continue;
  await sign(api.tx.router.sell(222,id,(5000n*10n**18n).toString(),'0',[{pool:'Omnipool',assetIn:222,assetOut:id}]),`${name}.acquire-${id}`,pair);
 }
 if(live){for(const pair of [pools,replay])console.log(pair.address.slice(0,8),JSON.stringify(Object.fromEntries(await Promise.all([420,1001,9001,5,1000085].map(async id=>[id,(await api.call.currenciesApi.account(id,pair.address)).free.toString()])))));}
}finally{await c.api.disconnect();}
