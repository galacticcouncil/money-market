// Lark only: deposits, ramp and unwinds share one PRIME lane. At 50 HOLLAR a trade and
// 1 HOLLAR/s of budget the deploys take every turn and the loop never levers. Raise both
// directions to the profile's trade size, budget and refill (Lark 4: 1,000, 10,000, 10/s;
// Lark 0: 2,500, 25,000, 50/s), with the source's own tranches to match; the 6 bps price
// limit and 60 s pacing stay.
// The markets peg resupplies nearly every PRIME the loop buys, so refill its inventory too.
import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {trade,capacity,refill,pegPrime,approval}=profile.primeLanes,n=x=>x.toLocaleString('en-US');
const c=await context();
try{
 const {r,api,govEvm,enact,save}=c;
 const abi=artifact('ExecutionController').abi,policy=r.executionPolicy,source=r.addresses.source.toLowerCase();
 const budget=name=>policy.budgets.find(b=>b.name===name);
 const lanes=['entry','unwind'].map(name=>{
  const b=budget(name),l=policy.limits.find(x=>x.consumer.toLowerCase()===source&&x.group===b.group);
  assert.ok(b&&l,`${name} lane missing from the journal`);
  const unit=name==='entry'?10n**18n:10n**6n;
  return {name,b,l,capacity:BigInt(capacity)*unit,refill:BigInt(refill)*unit,maximum:BigInt(trade)*unit};
 });
 const arb='0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex'),prime=BigInt(pegPrime)*10n**6n;
 const label=`lark-prime-throughput-${trade}`,id=`prime-throughput-${trade}`;
 if(prime>0n&&!r.governance.find(g=>g.label===label)?.verified){
  const room=await c.fuseHeadroom(43);
  assert.ok(room===null||prime<=room,'PRIME mint would trip the deposit fuse');
 }
 const calls=[];
 // a limit maximum may not exceed its budget capacity, so budgets go first
 for(const x of lanes)calls.push(govEvm(r.addresses.controller,abi,'configureBudget',[x.b.group,x.b.token,x.capacity,x.refill,BigInt(x.b.expiresAt)],500000));
 for(const x of lanes)calls.push(govEvm(r.addresses.controller,abi,'configureLimit',[x.l.consumer,x.l.input,x.l.output,x.l.group,BigInt(x.l.minimum),x.maximum],500000));
 if(prime>0n)calls.push(api.tx.currencies.updateBalance(c.arb.address,43,prime.toString()));
 await enact(label,calls);
 if(live){
  for(const x of lanes){x.b.capacity=x.capacity.toString();x.b.refillPerSecond=x.refill.toString();x.l.maximum=x.maximum.toString();}
  r.testnetApprovals??=[];
  if(!r.testnetApprovals.some(a=>a.id===id))r.testnetApprovals.push({id,scope:`Lark only; PRIME entry and unwind lanes ${n(trade)} a trade, ${refill}/s budget${prime>0n?`; ${pegPrime/1000}k test PRIME for the markets peg`:''}`,userAnswer:approval});
  save();
  for(const x of lanes){
   const l=await c.readSig(r.addresses.controller,'function limits(bytes32) view returns(bytes32,uint128,uint128)',[x.l.lane]);
   assert.equal(l[2],x.maximum,`${x.name} lane maximum not applied`);
  }
  console.log('arb PRIME',(await api.query.tokens.accounts(c.arb.address,43)).free.toString(),arb);
 }
 // the source caps every admission and ramp step at its own tranche too (50 at wiring)
 await enact(`lark-prime-tranches-${trade}`,[govEvm(r.addresses.source,artifact('SubLoop').abi,'setTranches',[BigInt(trade)*10n**18n,BigInt(trade)*10n**6n],500000)]);
 if(live){
  assert.equal(await c.readSig(r.addresses.source,'function deployTranche() view returns(uint256)'),BigInt(trade)*10n**18n);
  r.testnetApprovals.find(a=>a.id===id).scope+=`; source deploy/unwind tranches ${n(trade)}`;save();
 }
}finally{await c.api.disconnect();}
