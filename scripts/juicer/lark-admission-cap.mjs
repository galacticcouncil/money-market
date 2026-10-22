// Deposit admission on a new Lark: CollateralVault.deposit reverts above the source's deficit cap,
// and fresh loops start at 50 bps. Ramping a new deposit to the target costs about that much, so
// at 50 deposits stall behind the loop's own entry cost (lark 4 for days, lark 0 for 6.5 h).
// the profile's cap, with the keepers' DEFICIT_STOP_BPS/DEFICIT_RESUME_BPS set to match.
import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
assert.ok(!profile.legacy,`${profile.name} keeps its own admission (lark-admission-cap on its ops branch)`);
assert.ok(profile.admission,`profile ${profile.name} has no admission cap`);
const {bps:CAP,approval}=profile.admission,LABEL=`admission-cap-${CAP}`;
const c=await context();
try{
 const {r,read,govEvm,enact,save}=c,source=r.addresses.source;
 assert.ok(r.governance.find(g=>g.label==='bind-execution-controller')?.verified,'finish core wiring first');
 r.testnetApprovals??=[];
 if(!r.testnetApprovals.some(x=>x.id==='lark-admission-cap'))r.testnetApprovals.push({id:'lark-admission-cap',scope:'Lark only; deposit admission deficit',maxDeficitBps:CAP,userAnswer:approval});
 if(Number(await read('SubLoop',source,'admissionMaxDeficitBps'))!==CAP){
  await enact(LABEL,[govEvm(source,artifact('SubLoop').abi,'setAdmissionMaxDeficitBps',[CAP],500000)]);
 }
 if(live){
  assert.equal(Number(await read('SubLoop',source,'admissionMaxDeficitBps')),CAP);
  r.checks.admissionCap={bps:CAP,keeperStopBps:Number(profile.stack.keeperEnv?.DEFICIT_STOP_BPS??0),keeperResumeBps:Number(profile.stack.keeperEnv?.DEFICIT_RESUME_BPS??0)};save();
  console.log('ADMISSION',JSON.stringify(r.checks.admissionCap));
 }
}finally{await c.api.disconnect();}
