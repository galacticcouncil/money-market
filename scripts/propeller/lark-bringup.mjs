// Bring up the next version on a new Lark from zero: chain-level setup, contracts, governance
// wiring and parameters, one existing step script at a time. A dry run (the default) shows
// the plan and dry-runs the next pending step; --live runs every pending step in order and
// stops at the first that fails or waits on chain state. Every step lands in the
// bring-up log next to the deployment journal; a rerun resumes from the journals.
//   --plan        status only, nothing runs
//   --only=<id>   just that step, even if done
//   --from=<id>   start the scan at that step
//   --skip=<a,b>  go past these, recorded as skipped
import assert from 'node:assert/strict';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {profile,CORE_FILE,PRICES_FILE} from './lark-pins.mjs';
import {STEPS,stepStatus,schedule,missing} from './lark-bringup-steps.mjs';
const arg=name=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1];
const live=process.argv.includes('--live'),planOnly=process.argv.includes('--plan');
const only=arg('only'),from=arg('from'),skip=new Set(arg('skip')?.split(',').filter(Boolean)??[]);
for(const id of [only,from,...skip])if(id)assert.ok(STEPS.some(s=>s.id===id),`unknown step ${id}`);
assert.ok(!(live&&planOnly),'--plan never runs anything');
// lark 4 runs the #62 contracts and is already up; --plan still shows its journal
if(!planOnly)assert.ok(!profile.legacy,`profile ${profile.name} is already up; the bring-up targets a new lark (--profile=next)`);
const here=fileURLToPath(new URL('.',import.meta.url)),root=join(here,'..','..');
const readJson=file=>existsSync(file)?JSON.parse(readFileSync(file,'utf8')):null;
const state=()=>({core:readJson(CORE_FILE),prices:readJson(PRICES_FILE)});
const log=readJson(profile.bringUp)??{profile:profile.name,deployment:profile.deployment,events:[]};
function record(event){
 log.genesis??=state().core?.genesis;
 log.events.push({at:new Date().toISOString(),mode:live?'live':'dry-run',...event});
 writeFileSync(profile.bringUp,JSON.stringify(log,null,2)+'\n');
}
const s0=state();
console.log(`bring-up ${profile.name}: deployment ${profile.deployment}, chain ${profile.chainName??'unpinned'}, genesis ${profile.genesis??'unpinned'}`);
console.log(`journal ${CORE_FILE}${s0.core?'':' (none yet)'}; prices ${PRICES_FILE}; log ${profile.bringUp}`);
STEPS.forEach((step,i)=>{
 const status=stepStatus(step,s0),note=step.live?' [live only]':'';
 console.log(`${String(i+1).padStart(2)} ${step.id.padEnd(15)}${(skip.has(step.id)&&status!=='done'?'skip':status).padEnd(12)}${step.what}${note}`);
});
console.log(`stack ${profile.stack.name}: ${profile.stack.file}, manifest ${profile.manifest} as config ${profile.stack.manifestConfig}`);
const unset=[...new Set(STEPS.flatMap(step=>missing(step,profile,process.env)))];
if(unset.length)console.log(`unset: ${unset.join(', ')}`);
if(planOnly)process.exit(0);
const ran=new Set(),skipped=[];
for(;;){
 const next=schedule(STEPS,state(),{live,only,from,skip,ran});
 if(!next){console.log(!live?'nothing to dry-run':only?`${only} finished`:skipped.length?`bring-up complete except ${skipped.join(', ')}`:'bring-up complete');break;}
 if(next.skip){record({step:next.skip.id,skipped:true});ran.add(next.skip.id);skipped.push(next.skip.id);console.log('SKIPPED',next.skip.id);continue;}
 if(next.stop){record({step:next.stop.id,stopped:next.stop.reason});console.log('STOP',next.stop.id,next.stop.reason);process.exitCode=1;break;}
 const step=next.run,needs=missing(step,profile,process.env);
 if(needs.length){record({step:step.id,stopped:`unset ${needs.join(', ')}`});console.log('STOP',step.id,'needs',needs.join(', '));process.exitCode=1;break;}
 const args=[join(here,step.script),...(step.args??[]),...(live?['--live']:[])];
 // only the price steps journal elsewhere; a stale PROPELLER_LARK_RESULT must not redirect the rest
 const {PROPELLER_LARK_RESULT,...inherited}=process.env;
 const env={...inherited,LARK_PROFILE:profile.name,...(step.journal==='prices'?{PROPELLER_LARK_RESULT:PRICES_FILE}:{})};
 console.log('RUN',step.id,live?'live':'dry run',`node ${args.map(a=>a.replace(root+'/','')).join(' ')}`);
 const startedAt=new Date().toISOString(),result=spawnSync(process.execPath,args,{cwd:root,env,stdio:'inherit'});
 ran.add(step.id);
 const done=step.output?result.status===0:stepStatus(step,state())==='done';
 record({step:step.id,startedAt,exitCode:result.status,signal:result.signal??undefined,done});
 if(result.status!==0){console.log('FAILED',step.id,'exit',result.status??result.signal,'; fix and rerun to resume');process.exitCode=1;break;}
 if(!live){console.log('DRY RUN OK',step.id,'; --live runs it and continues');break;}
 if(!done){console.log('NOT DONE',step.id,'ran but the journal does not show it complete (waiting on chain state?); rerun to resume');process.exitCode=1;break;}
}
