import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
import {profile,primeCapNeed,primeCapIds} from './lark-pins.mjs';
// lark 0 keeps 6 bps behind a peg that pays the fee; a profit-seeking arb's band needs more
const {shortfallBps:CAP,approval}=profile.primeCap,ids=primeCapIds(CAP);
const c=await context();
try{
 const {r,govEvm,enact,save,api}=c;
 if(profile.peg){
  const feePpm=(await api.query.stableswap.pools(143)).unwrap().fee.toNumber(),need=primeCapNeed(feePpm,profile.peg);
  assert.ok(CAP>=need,`a ${CAP} bps PRIME cap stalls inside the arb's band (pool 143 fee ${feePpm/100} bps, arb profit ${profile.peg.sellProfitBps}/${profile.peg.buyProfitBps} bps): raise primeCap to ${need} or lower the fee (lark-prime-pool.mjs --fee-ppm)`);
 }
 r.testnetApprovals??=[];
 if(!r.testnetApprovals.some(a=>a.id===ids.approval))r.testnetApprovals.push({id:ids.approval,scope:'Lark only; PRIME/HOLLAR entry and unwind',maxShortfallBps:CAP,userAnswer:approval});
 const lanes=r.executionPolicy.limits.filter(l=>l.consumer.toLowerCase()===r.addresses.source.toLowerCase());assert.equal(lanes.length,2);
 const calls=lanes.map(l=>govEvm(r.addresses.controller,artifact('ExecutionController').abi,'configurePrice',[l.lane,CAP,l.safety],500000));
 calls.push(govEvm(r.addresses.source,artifact('SubLoop').abi,'configureDca',[222,43,1043,143,CAP*100],500000));
 await enact(ids.label,calls);
 if(live){for(const l of lanes)l.maxShortfallBps=CAP;r.sourceSlippagePpm=CAP*100;save();}
 const peg=(await api.query.stableswap.poolPegs(143)).unwrap().toJSON();
 const [num,den]=peg.current[0].map(BigInt),price=await c.readSig(r.oracles.find(o=>o.assetId===43).address,'function latestAnswer() view returns(int256)');
 const current=num*100000000n/den,diff=current>price?current-price:price-current;
 assert.ok(diff*10000n<=price,'pool peg has not converged within 1bp');
 await enact('restore-original-prime-peg-pacing',[api.tx.stableswap.updatePoolMaxPegUpdate(143,r.previousPrimePeg.maxPegUpdate)]);
 r.checks.primePegCaughtUp={current:current.toString(),target:price.toString(),restoredMaxPegUpdate:r.previousPrimePeg.maxPegUpdate};save();
 await c.mintTestHollar('arb.refill-hollar-with-quote-reserve','0x'+Buffer.from(c.arb.publicKey.slice(0,20)).toString('hex'),10000n*10n**18n);
}finally{await c.api.disconnect();}
