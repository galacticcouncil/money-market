// Lark only: pool sync sells EVM aTokens it cannot mint. Mint their Token-type
// underlying within the deposit fuse and wrap it, so inventory never comes
// from the omnipool it corrects. The stash lets the bot wrap more itself.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const WRAPS=[
 {mint:5,amount:5000n*10n**10n,out:1001,route:[{pool:'Aave',assetIn:5,assetOut:1001}]},
 {mint:1000809,amount:10n*10n**18n,out:420,route:[{pool:{Stableswap:4200},assetIn:1000809,assetOut:4200},{pool:'Aave',assetIn:4200,assetOut:420}]},
];
const STASH=[[5,100000n*10n**10n],[40,200n*10n**9n],[1000809,15n*10n**18n]];
const c=await context();
try{
 const {api,r,enact,sign}=c;
 const pools=new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261007-pools');
 const withinFuse=async(label,mints)=>{
  if(r.governance.find(g=>g.label===label)?.verified)return;
  for(const [id,amount] of mints){
   const limit=(await api.query.assetRegistry.assets(id)).unwrap().xcmRateLimit.unwrapOr(null)?.toBigInt();
   const state=(await api.query.circuitBreaker.assetLockdownState(id)).unwrapOr(null);
   if(limit===undefined||!state)continue;
   assert.ok(state.isUnlocked,`${id} is in lockdown`);
   const used=(await api.query.tokens.totalIssuance(id)).toBigInt()-state.asUnlocked[1].toBigInt();
   assert.ok(amount<=limit-used,`${id}: mint would trip the deposit fuse`);
  }
 };
 await withinFuse('pools-wrap-inventory',WRAPS.map(w=>[w.mint,w.amount]));
 await enact('pools-wrap-inventory',WRAPS.map(w=>api.tx.currencies.updateBalance(pools.address,w.mint,w.amount.toString())));
 if(live)for(const w of WRAPS){
  if(r.calls.some(x=>x.label===`pools.wrap-${w.out}`&&x.blockHash))continue;
  const tx=minimum=>api.tx.router.sell(w.mint,w.out,w.amount.toString(),minimum.toString(),w.route);
  const dry=await api.call.dryRunApi.dryRunCall({system:{Signed:pools.address}},tx(0n),4);
  assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`wrap ${w.out} dry run failed`);
  const out=BigInt(dry.asOk.emittedEvents.find(e=>e.section==='router'&&e.method==='Executed').data[3].toString());
  await sign(tx(out*99n/100n),`pools.wrap-${w.out}`,pools);
  console.log('WRAPPED',w.out,(await api.call.currenciesApi.account(w.out,pools.address)).free.toString());
 }
 await withinFuse('pools-underlying-stash',STASH);
 await enact('pools-underlying-stash',STASH.map(([id,amount])=>api.tx.currencies.updateBalance(pools.address,id,amount.toString())));
 if(live)for(const [id] of STASH)assert.equal((await api.query.tokens.accounts(pools.address,id)).reserved.toBigInt(),0n,`${id} stash parked by the fuse`);
}finally{await c.api.disconnect();}
