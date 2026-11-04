// The launch proposal juicer.ts wrote (JUICER_PLAN_OUT) as ONE root referendum through the lark's own
// governance, then the enactment block and every block it scheduled checked for failed calls.
//   node lark-launch-enact.mjs <plan.json> [--live]
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {context,live} from './lark-context.mjs';
import {failedEvent,executedBuys} from './lark-launch.mjs';
const planFile=process.argv.slice(2).find(a=>!a.startsWith('--'));
assert.ok(planFile,'usage: lark-launch-enact.mjs <plan.json> [--live]');
const plan=JSON.parse(readFileSync(planFile,'utf8')),LABEL='juicer-launch';
assert.ok(plan.proposal,'the plan has no proposal: nothing to enact');
const c=await context();
try{
 const {api,r,save,enact}=c;
 const call=api.createType('Call',plan.proposal.hex);
 assert.equal(`${call.section}.${call.method}`,'utility.batchAll');
 assert.equal(call.hash.toHex(),plan.proposal.hash,'the proposal hex is not the planned proposal');
 // enact() submits utility.batchAll(calls): the same call, so the same preimage
 assert.equal(api.tx.utility.batchAll(call.args[0]).method.hash.toHex(),plan.proposal.hash);
 await enact(LABEL,call.args[0]);
 if(!live)process.exit(0);
 const rec=r.governance.find(g=>g.label===LABEL);
 assert.ok(rec?.verified&&rec.enactment,'the referendum has not enacted');
 const first=rec.enactment.block,blocks=plan.batches.map((_,i)=>first+i);
 const until=Date.now()+600000;
 while((await api.rpc.chain.getHeader()).number.toNumber()<blocks.at(-1)+1){
  assert.ok(Date.now()<until,'the scheduled batches did not come up');
  await new Promise(resolve=>setTimeout(resolve,3000));
 }
 const rows=[];
 for(const [i,n] of blocks.entries()){
  const at=await api.at(await api.rpc.chain.getBlockHash(n));
  const events=(await at.query.system.events()).map(({event})=>({section:event.section,method:event.method,data:event.data.toJSON()}));
  const count=k=>events.filter(e=>`${e.section}.${e.method}`===k).length;
  rows.push({block:n,batch:i,events:events.length,evmExecuted:count('evm.Executed'),executedFailed:count('evm.ExecutedFailed'),
   treasury:count('dispatcher.TreasuryManagerCallDispatched'),dispatched:events.filter(e=>e.section==='scheduler'&&e.method==='Dispatched').map(e=>e.data),
   failures:events.filter(e=>failedEvent(e.section,e.method,e.data)).map(e=>`${e.section}.${e.method} ${JSON.stringify(e.data)}`),
   routerExecuted:events.filter(e=>e.section==='router'&&e.method==='Executed').map(e=>e.data.slice(0,4).map(x=>BigInt(x).toString())),
   agendaLeft:(await api.query.scheduler.agenda(n)).filter(t=>t.isSome).length});
 }
 const buys=executedBuys(rows,plan.treasuryBuys);
 r.launchReferendum={ref:rec.ref,preimage:{hash:rec.hash,len:rec.len},submittedBlock:rec.submittedBlock,enactmentBlock:first,blocks:rows,treasuryBuys:buys,
  clean:rows.every(b=>!b.failures.length&&!b.agendaLeft&&b.dispatched.length)&&buys.every(b=>b.withinBound)};
 save();
 for(const b of rows)console.log('BLOCK',b.block,'batch',b.batch,'evm',b.evmExecuted,'failed',b.executedFailed,'treasury',b.treasury,'failures',b.failures.length,
  ...b.routerExecuted.map(([i,o,amountIn,out])=>`buy ${out} of ${o} for ${amountIn} of ${i}`));
 assert.ok(buys.every(b=>b.withinBound),`a treasury buy did not execute within its bound: ${JSON.stringify(buys)}`);
 assert.ok(r.launchReferendum.clean,`the launch referendum left failures: ${JSON.stringify(rows.map(b=>[b.block,b.failures,b.agendaLeft]))}`);
 console.log('LAUNCH ENACTED',rec.ref,'at',first,'clean');
}finally{await c.api.disconnect();}
