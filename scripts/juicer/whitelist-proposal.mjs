// The launch call through the whitelist: a Technical Committee motion whitelists its hash, then a
// WhitelistedCaller referendum dispatches it, the call inline in its preimage. Read-only; prints what to sign.
//   node scripts/juicer/whitelist-proposal.mjs <plan.json> [out.json]   WS (default the mainnet archive)
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync,writeFileSync} from 'node:fs';
const require=createRequire(import.meta.url);
const {ApiPromise,WsProvider}=require('@polkadot/api');
const {blake2AsHex}=require('@polkadot/util-crypto');
const [planFile,outFile]=process.argv.slice(2);
assert.ok(planFile,'usage: whitelist-proposal.mjs <plan.json> [out.json]');
const WS=process.env.WS||'wss://hdx.tarn.hydration.cloud';
const plan=JSON.parse(readFileSync(planFile,'utf8'));
const api=await ApiPromise.create({provider:new WsProvider(WS),noInitWarn:true});
try{
 const inner=api.createType('Call',plan.proposal.hex);
 assert.equal(inner.hash.toHex(),plan.proposal.hash,'the plan hex and hash disagree');
 // TechCommitteeMajority: ayes * 2 >= members
 const members=(await api.query.technicalCommittee.members()).length,threshold=Math.ceil(members/2);
 const whitelist=api.tx.whitelist.whitelistCall(inner.hash);
 const motion=api.tx.technicalCommittee.propose(threshold,whitelist,whitelist.method.encodedLength);
 const outer=api.tx.whitelist.dispatchWhitelistedCallWithPreimage(inner).method;
 const outerHex=outer.toHex(),outerHash=blake2AsHex(outerHex),outerLen=(outerHex.length-2)/2;
 // track names are padded byte arrays
 const trackName=t=>String(t.toHuman().name).replace(/\0/g,'').trim();
 const [trackId,track]=api.consts.referenda.tracks.find(([,t])=>trackName(t)==='whitelisted_caller');
 const note=api.tx.preimage.notePreimage(outerHex);
 const submit=api.tx.referenda.submit({Origins:'WhitelistedCaller'},{Lookup:{hash:outerHash,len:outerLen}},{After:1});
 // the scheduler runs the referendum's call at enactment: the inline call's weight plus the whitelist's
 const weight=(await api.tx(outer).paymentInfo((await api.call.evmAccountsApi.accountId(plan.governance)).toString())).weight;
 const max=api.consts.scheduler.maximumWeight,pct=(a,b)=>`${(Number(a.toBigInt())/Number(b.toBigInt())*100).toFixed(2)}%`;
 const out={
  inner:{hash:inner.hash.toHex(),len:inner.encodedLength},
  motion:{threshold,members,proposal:whitelist.method.toHex(),proposalHash:whitelist.method.hash.toHex(),lengthBound:whitelist.method.encodedLength,call:motion.method.toHex()},
  referendum:{track:{id:trackId.toNumber(),name:trackName(track),decisionDeposit:track.decisionDeposit.toString(),preparePeriod:track.preparePeriod.toNumber(),
   decisionPeriod:track.decisionPeriod.toNumber(),confirmPeriod:track.confirmPeriod.toNumber(),minEnactmentPeriod:track.minEnactmentPeriod.toNumber()},
   origin:{Origins:'WhitelistedCaller'},preimage:{hash:outerHash,len:outerLen,hex:outerHex},notePreimage:{len:note.method.encodedLength},submit:submit.method.toHex()},
  weight:{ref:weight.refTime.toString(),proof:weight.proofSize.toString(),ofScheduler:`${pct(weight.refTime,max.refTime)} ref, ${pct(weight.proofSize,max.proofSize)} proof`},
 };
 assert.ok(weight.refTime.toBigInt()<max.refTime.toBigInt()&&weight.proofSize.toBigInt()<max.proofSize.toBigInt(),'the whitelisted call does not fit the scheduler');
 console.log(`===== the launch call: ${out.inner.hash}, ${out.inner.len} bytes =====`);
 console.log(`1. a TC member proposes, ${threshold} of ${members} ayes, then closes: technicalCommittee.propose(${threshold}, whitelist.whitelistCall(${out.inner.hash}), ${out.motion.lengthBound})`);
 console.log(`   call ${out.motion.call}`);
 console.log(`   motion hash ${out.motion.proposalHash}`);
 console.log(`2. preimage.notePreimage of the referendum's call, whitelist.dispatchWhitelistedCallWithPreimage(<the launch call>): ${outerLen} bytes, hash ${outerHash}`);
 console.log(`3. referenda.submit on ${out.referendum.track.name} (track ${out.referendum.track.id}): ${out.referendum.submit}`);
 console.log(`4. referenda.placeDecisionDeposit(<index>): ${BigInt(out.referendum.track.decisionDeposit)/10n**12n} HDX`);
 console.log(`   periods: prepare ${out.referendum.track.preparePeriod}, decision up to ${out.referendum.track.decisionPeriod}, confirm ${out.referendum.track.confirmPeriod}, enactment ${out.referendum.track.minEnactmentPeriod} blocks after approval`);
 console.log(`   enactment weight ${out.weight.ofScheduler} of the scheduler's; batches 1-${plan.batches.length-1} follow, one block each`);
 if(outFile){writeFileSync(outFile,JSON.stringify(out,null,2)+'\n');console.log('written',outFile);}
}finally{await api.disconnect();}
