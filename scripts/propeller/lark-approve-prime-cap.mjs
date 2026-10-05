import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
const c=await context();
try{
 const {r,govEvm,enact,save,api}=c;
 r.testnetApprovals??=[];
 if(!r.testnetApprovals.some(a=>a.id==='prime-six-bps'))r.testnetApprovals.push({id:'prime-six-bps',scope:'Lark only; PRIME/HOLLAR entry and unwind',maxShortfallBps:6,userAnswer:'Use 6 bps on Lark only (Recommended)'});
 const lanes=r.executionPolicy.limits.filter(l=>l.consumer.toLowerCase()===r.addresses.source.toLowerCase());assert.equal(lanes.length,2);
 const calls=lanes.map(l=>govEvm(r.addresses.controller,artifact('ExecutionController').abi,'configurePrice',[l.lane,6,l.safety],500000));
 calls.push(govEvm(r.addresses.source,artifact('SubLoop').abi,'configureDca',[222,43,1043,143,600],500000));
 await enact('approved-lark-only-prime-six-bps',calls);
 if(live){for(const l of lanes)l.maxShortfallBps=6;r.sourceSlippagePpm=600;save();}
 const peg=(await api.query.stableswap.poolPegs(143)).unwrap().toJSON();
 const [num,den]=peg.current[0].map(BigInt),price=await c.readSig(r.oracles.find(o=>o.assetId===43).address,'function latestAnswer() view returns(int256)');
 const current=num*100000000n/den,diff=current>price?current-price:price-current;
 assert.ok(diff*10000n<=price,'pool peg has not converged within 1bp');
 await enact('restore-original-prime-peg-pacing',[api.tx.stableswap.updatePoolMaxPegUpdate(143,r.previousPrimePeg.maxPegUpdate)]);
 r.checks.primePegCaughtUp={current:current.toString(),target:price.toString(),restoredMaxPegUpdate:r.previousPrimePeg.maxPegUpdate};save();
 await c.sign(api.tx.currencies.transfer(c.arb.address,222,(10000n*10n**18n).toString()),'arb.refill-hollar-with-quote-reserve');
}finally{await c.api.disconnect();}
