// Lark only: stableswap sync needs both sides of every pool it corrects. Mint the
// Token-type assets within the deposit fuse (about 5% of their largest pool) and
// wrap the aToken sides as the pools signer, all from one referendum, so nothing
// races the live pools bot's nonce.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const u=(n,d)=>BigInt(Math.round(n*1e6))*10n**BigInt(d)/1000000n;
// --top-up=<asset>:<units> mints one more Token-type asset under its own label
const topUp=process.argv.find(a=>a.startsWith('--top-up='))?.split('=')[1]?.split(':');
const BASE=[
 [10,u(37500,6)],[18,u(13,18)],[20,u(2.5,18)],[21,u(8460,6)],[22,u(29400,6)],[23,u(7700,6)],[46,u(6600,18)],
 [15,u(25000,10)],[1000625,u(2000,18)],[1000745,u(2660,18)],[1000766,u(15660,6)],[1000767,u(17240,6)],
 [34,u(0.5,18)],[44,u(20800,6)],[1000752,u(380,9)],
];
// aToken sides: supply part of the minted underlying through the money market
const BASE_WRAPS=[[10,1002,u(29500,6)],[22,1003,u(26300,6)],[34,1007,u(0.5,18)],[44,1044,u(20800,6)],[1000752,1009,u(380,9)]];
const c=await context();
try{
 const {api,r,enact}=c;
 const pools=new Keyring({type:'sr25519'}).addFromUri(profile.signers.pools);
 const decimals=topUp?(await api.query.assetRegistry.assets(Number(topUp[0]))).unwrap().decimals.toString():0;
 const MINTS=topUp?[[Number(topUp[0]),u(Number(topUp[1]),Number(decimals))]]:BASE,WRAPS=topUp?[]:BASE_WRAPS;
 const label=topUp?`pools-stable-topup-${topUp[0]}-${topUp[1]}`:'pools-stable-inventory';
 if(!r.governance.find(g=>g.label===label)?.verified)for(const [id,amount] of MINTS){
  const limit=(await api.query.assetRegistry.assets(id)).unwrap().xcmRateLimit.unwrapOr(null)?.toBigInt();
  const state=(await api.query.circuitBreaker.assetLockdownState(id)).unwrapOr(null);
  if(limit===undefined||!state)continue;
  assert.ok(state.isUnlocked,`${id} is in lockdown`);
  const used=(await api.query.tokens.totalIssuance(id)).toBigInt()-state.asUnlocked[1].toBigInt();
  assert.ok(amount<=limit-used,`${id}: mint would trip the deposit fuse`);
 }
 const calls=[
  ...MINTS.map(([id,amount])=>api.tx.currencies.updateBalance(pools.address,id,amount.toString())),
  ...WRAPS.map(([from,to,amount])=>api.tx.utility.dispatchAs({system:{Signed:pools.address}},
   api.tx.router.sell(from,to,amount.toString(),(amount*99n/100n).toString(),[{pool:'Aave',assetIn:from,assetOut:to}]))),
 ];
 // dispatchAs reports an inner failure as an event, not a failed batch
 const dry=await api.call.dryRunApi.dryRunCall({system:'Root'},api.tx.utility.batchAll(calls),4);
 assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`${label}: dry run failed`);
 const dispatched=dry.asOk.emittedEvents.filter(e=>e.section==='utility'&&e.method==='DispatchedAs');
 assert.equal(dispatched.length,WRAPS.length);
 for(const e of dispatched)assert.ok(e.data[0].isOk,`${label}: a wrap fails: ${e.data[0]}`);
 await enact(label,calls);
 if(live){
  for(const [id] of MINTS)assert.equal((await api.query.tokens.accounts(pools.address,id)).reserved.toBigInt(),0n,`${id} parked by the fuse`);
  for(const [,to] of WRAPS)console.log('WRAPPED',to,(await api.call.currenciesApi.account(to,pools.address)).free.toString());
 }
}finally{await c.api.disconnect();}
