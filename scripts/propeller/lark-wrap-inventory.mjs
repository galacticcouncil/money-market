// Lark only: pool sync sells EVM aTokens it cannot mint. Mint their Token-type
// underlying within the deposit fuse and wrap it, so inventory never comes
// from the omnipool it corrects.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const WRAPS=[
 {mint:5,amount:5000n*10n**10n,out:1001,route:[{pool:'Aave',assetIn:5,assetOut:1001}]},
 {mint:1000809,amount:10n*10n**18n,out:420,route:[{pool:{Stableswap:4200},assetIn:1000809,assetOut:4200},{pool:'Aave',assetIn:4200,assetOut:420}]},
];
const c=await context();
try{
 const {api,r,save,enact,sign}=c;
 const pools=new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261007-pools');
 if(!r.governance.find(g=>g.label==='pools-wrap-inventory')?.verified)for(const w of WRAPS){
  const limit=(await api.query.assetRegistry.assets(w.mint)).unwrap().xcmRateLimit.unwrapOr(null)?.toBigInt();
  const state=(await api.query.circuitBreaker.assetLockdownState(w.mint)).unwrapOr(null);
  if(limit===undefined||!state)continue;
  assert.ok(state.isUnlocked,`${w.mint} is in lockdown`);
  const used=(await api.query.tokens.totalIssuance(w.mint)).toBigInt()-state.asUnlocked[1].toBigInt();
  assert.ok(w.amount<=limit-used,`${w.mint}: mint would trip the deposit fuse`);
 }
 await enact('pools-wrap-inventory',WRAPS.map(w=>api.tx.currencies.updateBalance(pools.address,w.mint,w.amount.toString())));
 if(live)for(const w of WRAPS){
  const tx=minimum=>api.tx.router.sell(w.mint,w.out,w.amount.toString(),minimum.toString(),w.route);
  const dry=await api.call.dryRunApi.dryRunCall({system:{Signed:pools.address}},tx(0n),4);
  assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`wrap ${w.out} dry run failed`);
  const out=BigInt(dry.asOk.emittedEvents.find(e=>e.section==='router'&&e.method==='Executed').data[3].toString());
  await sign(tx(out*99n/100n),`pools.wrap-${w.out}`,pools);
  console.log('WRAPPED',w.out,(await api.call.currenciesApi.account(w.out,pools.address)).free.toString());
 }
}finally{await c.api.disconnect();}
