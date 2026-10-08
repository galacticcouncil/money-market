// Lark only: deposits, ramp and unwinds share one PRIME lane. At 50 HOLLAR a trade and
// 1 HOLLAR/s of budget the deploys take every turn and the loop never levers. Raise both
// directions to 1,000 a trade and 10/s, with the source's own tranches to match; the 6 bps
// price limit and 60 s pacing stay.
// The markets peg resupplies nearly every PRIME the loop buys, so refill its inventory too.
import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
const c=await context();
try{
 const {r,api,govEvm,enact,save}=c;
 const abi=artifact('ExecutionController').abi,policy=r.executionPolicy,source=r.addresses.source.toLowerCase();
 const budget=name=>policy.budgets.find(b=>b.name===name);
 const lanes=['entry','unwind'].map(name=>{
  const b=budget(name),l=policy.limits.find(x=>x.consumer.toLowerCase()===source&&x.group===b.group);
  assert.ok(b&&l,`${name} lane missing from the journal`);
  const unit=name==='entry'?10n**18n:10n**6n;
  return {name,b,l,capacity:10000n*unit,refill:10n*unit,maximum:1000n*unit};
 });
 const arb='0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex'),prime=150000n*10n**6n;
 if(!r.governance.find(g=>g.label==='lark-prime-throughput-1000')?.verified){
  const limit=(await api.query.assetRegistry.assets(43)).unwrap().xcmRateLimit.unwrap().toBigInt();
  const state=(await api.query.circuitBreaker.assetLockdownState(43)).unwrap();
  assert.ok(state.isUnlocked,'PRIME is in lockdown');
  assert.ok(prime<=limit-((await api.query.tokens.totalIssuance(43)).toBigInt()-state.asUnlocked[1].toBigInt()),'PRIME mint would trip the deposit fuse');
 }
 const calls=[];
 // a limit maximum may not exceed its budget capacity, so budgets go first
 for(const x of lanes)calls.push(govEvm(r.addresses.controller,abi,'configureBudget',[x.b.group,x.b.token,x.capacity,x.refill,BigInt(x.b.expiresAt)],500000));
 for(const x of lanes)calls.push(govEvm(r.addresses.controller,abi,'configureLimit',[x.l.consumer,x.l.input,x.l.output,x.l.group,BigInt(x.l.minimum),x.maximum],500000));
 calls.push(api.tx.currencies.updateBalance(c.arb.address,43,prime.toString()));
 await enact('lark-prime-throughput-1000',calls);
 if(live){
  for(const x of lanes){x.b.capacity=x.capacity.toString();x.b.refillPerSecond=x.refill.toString();x.l.maximum=x.maximum.toString();}
  r.testnetApprovals??=[];
  if(!r.testnetApprovals.some(a=>a.id==='prime-throughput-1000'))r.testnetApprovals.push({id:'prime-throughput-1000',scope:'Lark only; PRIME entry and unwind lanes 1,000 a trade, 10/s budget; 150k test PRIME for the markets peg',userAnswer:'make sure the lark4 prime loop leveraging continues'});
  save();
  for(const x of lanes){
   const l=await c.readSig(r.addresses.controller,'function limits(bytes32) view returns(bytes32,uint128,uint128)',[x.l.lane]);
   assert.equal(l[2],x.maximum,`${x.name} lane maximum not applied`);
  }
  console.log('arb PRIME',(await api.query.tokens.accounts(c.arb.address,43)).free.toString(),arb);
 }
 // the source caps every admission and ramp step at its own tranche too (50 at wiring)
 await enact('lark-prime-tranches-1000',[govEvm(r.addresses.source,artifact('SubLoop').abi,'setTranches',[1000n*10n**18n,1000n*10n**6n],500000)]);
 if(live){
  assert.equal(await c.readSig(r.addresses.source,'function deployTranche() view returns(uint256)'),1000n*10n**18n);
  r.testnetApprovals.find(a=>a.id==='prime-throughput-1000').scope+='; source deploy/unwind tranches 1,000';save();
 }
}finally{await c.api.disconnect();}
