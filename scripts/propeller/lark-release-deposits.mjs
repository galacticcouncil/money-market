// Lark only: test mints above an asset's deposit limit were parked by the
// circuit breaker. Lift those lockdowns, release the parked test balances and
// give pool sync GSOL via jitoSOL -> 2-Pool-GSOL -> GSOL, off the omnipool.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,live} from './lark-context.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const JITOSOL=40,GSOL_SHARE=90001,GSOL=9001,JITOSOL_MINT=100n*10n**9n;
const c=await context();
try{
 const {api,r,save,enact,sign}=c;
 const pools=new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261007-pools');
 if(!r.depositRelease){
  const minted=new Map();
  const walk=call=>{
   if(`${call.section}.${call.method}`==='currencies.updateBalance')minted.set(`${call.args[0]}:${call.args[1]}`,[call.args[0].toString(),call.args[1].toNumber()]);
   for(const a of call.args)for(const x of a?.toArray?a.toArray():Array.isArray(a)?a:[a])if(x?.section)walk(x);
  };
  for(const g of r.governance)if(g.hex)walk(api.createType('Call',g.hex));
  const parked=[];
  for(const [who,id] of minted.values()){
   const amount=(await api.query.tokens.reserves(who,id)).find(x=>x.id.toUtf8()==='depositc')?.amount.toBigInt()??0n;
   if(amount>0n)parked.push({who,id,amount:amount.toString()});
  }
  const locked=[];
  for(const id of new Set(parked.map(p=>p.id)))if((await api.query.circuitBreaker.assetLockdownState(id)).unwrapOr(null)?.isLocked)locked.push(id);
  r.depositRelease={locked,parked,jitosol:{who:pools.address,amount:JITOSOL_MINT.toString()}};save();
 }
 const {locked,parked,jitosol}=r.depositRelease;
 console.log('PARKED',JSON.stringify(parked),'LOCKED',JSON.stringify(locked));
 await enact('release-parked-test-deposits',[
  ...locked.map(id=>api.tx.circuitBreaker.forceLiftLockdown(id)),
  ...parked.map(p=>api.tx.circuitBreaker.releaseDeposit(p.who,p.id)),
  api.tx.currencies.updateBalance(jitosol.who,JITOSOL,jitosol.amount),
 ]);
 const route=[{pool:{Stableswap:GSOL_SHARE},assetIn:JITOSOL,assetOut:GSOL_SHARE},{pool:'Aave',assetIn:GSOL_SHARE,assetOut:GSOL}];
 const dry=await api.call.dryRunApi.dryRunCall({system:{Signed:pools.address}},api.tx.router.sell(JITOSOL,GSOL,jitosol.amount,'0',route),4);
 if(live){
  for(const p of parked)assert.equal((await api.query.tokens.accounts(p.who,p.id)).reserved.toBigInt(),0n,`${p.who}:${p.id} still parked`);
  assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`gsol wrap dry run failed: ${dry.isOk?dry.asOk.executionResult:dry}`);
  const out=BigInt(dry.asOk.emittedEvents.find(e=>e.section==='router'&&e.method==='Executed').data[3].toString());
  await sign(api.tx.router.sell(JITOSOL,GSOL,jitosol.amount,(out*99n/100n).toString(),route),'pools.wrap-gsol',pools);
  r.checks.depositRelease=true;save();
  console.log('RELEASED',parked.length,'GSOL',(await api.call.currenciesApi.account(GSOL,pools.address)).free.toString());
 }
}finally{await c.api.disconnect();}
