// Lark only: fund simulated depositors (public test accounts 21..28) with an uneven
// split of about $100k of test collateral and lift the vault TVL caps to fit it.
// the deposits bot spends it; nothing here deposits.
import assert from 'node:assert/strict';
import {context,v,testAccount,live} from './lark-context.mjs';
const USERS=8,USD={ETH:45000,TBTC:55000},CAP={ETH:25n*10n**18n,TBTC:10n**18n},ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
const c=await context();
try{
 const {api,r,save,readSig,govEvm,enact,nativeAccount}=c;
 if(!r.depositor){
  // seeded log-uniform weights: a few whales, mostly small holders
  let seed=20261007;const rand=()=>((seed=Math.imul(seed^seed>>>15,seed|1)^seed+Math.imul(seed^seed>>>7,seed|61),(seed^seed>>>14)>>>0)/4294967296);
  const users=await Promise.all(Array.from({length:USERS},async(_,i)=>{const a=testAccount(21+i);return {index:21+i,address:a.address,who:await nativeAccount(a.address)};}));
  const plan=[];
  for(const vault of r.vaults){
   const price=await readSig(ORACLE,'function getAssetPrice(address) view returns(uint256)',[vault.asset]);
   const total=BigInt(USD[vault.name])*10n**26n/price;
   const weights=users.map(()=>BigInt(Math.floor(1e6*20**rand())));
   const sum=weights.reduce((a,b)=>a+b,0n),shares=weights.map(w=>total*w/sum);
   shares[0]+=total-shares.reduce((a,b)=>a+b,0n);
   plan.push({name:vault.name,vault:vault.address,assetId:vault.assetId,asset:vault.asset,total:total.toString(),usd:USD[vault.name],split:shares.map(String)});
  }
  r.depositor={users,plan};save();
 }
 const {users,plan}=r.depositor;
 // a mint above the fuse headroom is parked as reserved balance and locks the asset
 for(const [id,amount] of [...plan.map(p=>[p.assetId,BigInt(p.total)]),[20,BigInt(USERS)*2n*10n**17n]]){
  const limit=(await api.query.assetRegistry.assets(id)).unwrap().xcmRateLimit.unwrapOr(null)?.toBigInt();
  const state=(await api.query.circuitBreaker.assetLockdownState(id)).unwrapOr(null);
  if(limit===undefined||!state)continue;
  assert.ok(state.isUnlocked,`${id} is in lockdown`);
  const used=(await api.query.tokens.totalIssuance(id)).toBigInt()-state.asUnlocked[1].toBigInt();
  assert.ok(amount<=limit-used,`${id}: ${amount} exceeds fuse headroom ${limit-used}`);
 }
 const capAbi=v.parseAbi(['function setTvlCap(uint256)']);
 await enact('depositor-setup',[
  ...r.vaults.map(x=>govEvm(x.address,capAbi,'setTvlCap',[CAP[x.name]],500000)),
  ...users.flatMap((u,i)=>[api.tx.duster.whitelistAccount(u.who),
   api.tx.currencies.updateBalance(u.who,0,(10n*10n**12n).toString()),
   api.tx.currencies.updateBalance(u.who,20,(2n*10n**17n).toString()),
   ...plan.map(p=>api.tx.currencies.updateBalance(u.who,p.assetId,p.split[i]))]),
 ]);
 if(live){
  for(const u of users)for(const p of plan)assert.equal((await api.query.tokens.accounts(u.who,p.assetId)).reserved.toBigInt(),0n,`${u.address} ${p.name} parked by the fuse`);
  r.checks.depositorFunded=true;save();
 }
 for(const p of plan)console.log(p.name,'total',p.total,'usd',p.usd,'split',p.split.map(x=>(Number(x)/1e18).toFixed(4)).join(' '));
 for(const x of r.vaults)console.log(x.name,'tvlCap',await readSig(x.address,'function tvlCap() view returns(uint256)'));
}finally{await c.api.disconnect();}
