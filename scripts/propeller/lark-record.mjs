// Publish only the explicitly selected public Lark evidence, never service
// environment/configuration dumps or raw signed transaction journals.
import {readFileSync,writeFileSync,mkdirSync,existsSync,readdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../../propeller-vault/docs/evidence/lark-2026-10-05/',import.meta.url));
mkdirSync(root,{recursive:true});
const read=file=>JSON.parse(readFileSync(file,'utf8'));
const save=(name,data)=>writeFileSync(root+name,JSON.stringify(data,null,2)+'\n');
const r=read('/tmp/propeller-lark-20261005.json');
const pricing=read('/tmp/propeller-lark-prices-20261005.json');
const manifest=Object.fromEntries(['rpc','genesis','runtime','commit','startedAt','testnetOnly','addresses','vaults','market','oracles','feeRecipient','committee','synthAssetId','discountBps','testSigners','executionPolicy','testnetApprovals','sourceSlippagePpm','checks','previousOracles','previousPrimePeg','previousDiscount'].map(k=>[k,r[k]]));
manifest.status='testnet-active; staged-entry-proven; harvest-and-leveraged-exit-gates-open';
manifest.artifacts=Object.fromEntries(Object.entries({...r.artifacts,...pricing.artifacts}).map(([name,a])=>[name,{sha256:a.sha256}]));
manifest.hosting={stack:'propeller-oct2026',url:'https://swarmpit.lark.hydration.cloud',keeperCommit:'e3ec9cd',keeperImage:'galacticcouncil/propeller-lark-keeper@sha256:972ee604daba2ac70079c0fc989b7d1314798bbb37fecaa375e749e41e6908c8',botCommit:'f361bf8',botImage:'galacticcouncil/propeller-lark-bots@sha256:70c13bb2991431be8bcdd4615398d6fbbb48cccd7db8297ec39cf70f8ddb280a',singlePhysicalHost:true,operatorCount:2};
manifest.ui={pr:3978,commit:'95a20173daec6a6e7f4d3a4345f86bc67e27d445',url:'https://deploy-preview-3978--edge-hydra-app.netlify.app/strategies/propeller'};
save('deployment.json',manifest);
save('operations.json',{deployments:[...r.deployments,...pricing.deployments],calls:[...r.calls,...pricing.calls].map(c=>Object.fromEntries(['label','hash','nonce','signer','submittedAt','blockHash','success','evm','to','receipt','rejected'].filter(k=>c[k]!==undefined).map(k=>[k,c[k]]))),governance:r.governance.map(g=>({label:g.label,hash:g.hash,len:g.len,ref:g.ref,dryRunPassed:g.dryRunPassed,verified:g.verified,enactment:g.enactment,failure:g.failure}))});
for(const [src,dest]of [['/tmp/propeller-lark-observation.json','live-snapshot.json'],['/tmp/propeller-lark-harvest-diagnosis.json','harvest-diagnosis.json'],['/tmp/propeller-lark-pool-fees.json','pool-fees.json']])if(existsSync(src))save(dest,read(src));
for(const [src,dest]of [['/tmp/propeller-lark-readiness-live.log','readiness.log'],['/tmp/propeller-lark-keeper-tests.log','keeper-tests.log'],['/tmp/propeller-lark-bot-tests.log','bot-tests.log']])writeFileSync(root+dest,readFileSync(src));
const tasks=read('/tmp/propeller-lark-hosted-tasks.json');
save('service-tasks.json',tasks.map(t=>Object.fromEntries(['id','serviceName','state','desiredState','createdAt','updatedAt','error'].map(k=>[k,t[k]]))));
for(const name of ['keeper0','keeper1'])save(`${name}.json`,read(`/tmp/propeller-lark-${name}.json`).map(r=>({time:r.timestamp,task:r.task,line:r.line})));
const parse=line=>{try{return JSON.parse(line.trim());}catch{return null;}};
const markets=read('/tmp/propeller-lark-hosted-markets.json').map(r=>parse(r.line)).filter(Boolean);
const head=markets.filter(r=>r.name==='quote').at(-1)?.block;
save('market-observation.json',{latestQuoteBlock:head,quotes:markets.filter(r=>r.name==='quote'&&r.block===head),recentDecisions:markets.filter(r=>r.name!=='quote').slice(-30)});
const mirrors=read('/tmp/propeller-lark-hosted-mirror.json').map(r=>parse(r.line)).filter(Boolean);
save('oracle-observation.json',mirrors.slice(-18));
const arbs=markets.filter(r=>r.name==='arb-mined');
for(const name of ['markets-live','markets-fresh-head','markets-live-one']){
 const file=`/tmp/propeller-lark-${name}.log`;
 if(existsSync(file))for(const line of readFileSync(file,'utf8').split('\n')){const row=parse(line);if(row?.name==='arb-mined')arbs.push(row);}
}
save('arb-transactions.json',[...new Map(arbs.map(r=>[r.hash,r])).values()].sort((a,b)=>a.time.localeCompare(b.time)));
const checksums=readdirSync(root).filter(n=>n!=='SHA256SUMS').sort().map(n=>`${createHash('sha256').update(readFileSync(root+n)).digest('hex')}  ${n}`).join('\n');
writeFileSync(root+'SHA256SUMS',checksums+'\n');
console.log(`Recorded ${readdirSync(root).length} public evidence files in ${root}`);
