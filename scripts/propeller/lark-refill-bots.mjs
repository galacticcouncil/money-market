// Lark only: tops the market bots back up when they report `inventory-refill-needed` (or
// replay skips trades it cannot fund), through the seed mechanism: one governance batch per
// refill, deposit-fuse and facilitator checks, a journal entry. Each bot and asset refills to
// its cap at most once per --min-interval. A dry run (the default) leaves the journal alone.
//   --reports=<file,...>          bot log lines, docker or swarm output; - reads stdin
//   --since=<minutes>             only reports this recent, default 60
//   --min-interval=<hours>        between refills of one bot and asset, default 6
//   --cap=<bot>:<asset>:<units>   override a ceiling, repeatable
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
import {seedCalls,seedRound,recordSeed,botAddress,botEvm,HOLLAR_ID} from './lark-seed.mjs';
import {CAPS,parseReports,demands,recipe,planRefills,lastRefills,toUnits} from './lark-refill-plan.mjs';
const arg=(name,fallback)=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1]??fallback;
const files=arg('reports');
assert.ok(files,'usage: --reports=<file,...|-> [--since=<minutes>] [--min-interval=<hours>] [--cap=<bot>:<asset>:<units>] [--live]');
const now=Date.now(),minIntervalMs=Number(arg('min-interval',6))*3600000;
const wanted=demands(parseReports(files.split(',').map(f=>readFileSync(f==='-'?0:f,'utf8')).join('\n'),{since:now-Number(arg('since',60))*60000})).filter(d=>d.bot in profile.signers);
const caps=Object.fromEntries(Object.entries(CAPS).map(([bot,x])=>[bot,{...x}]));
for(const o of process.argv.filter(a=>a.startsWith('--cap='))){const [bot,asset,n]=o.slice(6).split(':');(caps[bot]??={})[Number(asset)]=Number(n);}
const OMNIPOOL='0x6d6f646c6f6d6e69706f6f6c0000000000000000000000000000000000000000';
const json=x=>JSON.stringify(x,(_,y)=>typeof y==='bigint'?y.toString():y);
const c=await context();
try{
 const {api,r,save}=c;
 r.refills??=[];
 // a refill that reached governance finishes as recorded before anything new is planned;
 // one that failed its checks before that never minted and is dropped
 let pending=r.refills.find(x=>!x.done&&!x.abandoned);
 if(pending&&!r.governance.some(g=>g.label===`bots-seed-${pending.round}`)){if(live){pending.abandoned='stopped before governance';save();}pending=undefined;}
 if(pending){
  assert.ok(live,`refill ${pending.round} is pending; --live resumes it`);
  await c.enact(`bots-seed-${pending.round}`,(await seedCalls(c,{plan:pending.plan})).calls);
  await recordSeed(c,{round:pending.round,plan:pending.plan,entry:{refill:true,at:pending.at,reports:pending.reports}});
  pending.done=true;save();console.log('RESUMED',pending.round);
 }else{
  const meta={};
  const registry=async id=>meta[id]??=(await api.query.assetRegistry.assets(id)).unwrapOr(null);
  for(const d of wanted)await registry(d.asset);
  const isToken=id=>meta[id]?.assetType.toString()==='Token';
  const held={},decimals={},headroom={};
  for(const d of wanted){
   const x=recipe(d.bot,d.asset,isToken);if(!x)continue;
   const key=`${d.bot}:${x.held}`,dec=Number((await registry(x.mint)).decimals.toString());
   held[key]??=(await api.call.currenciesApi.account(x.held,botAddress(d.bot))).free.toBigInt();
   decimals[x.mint]=dec;
   if(!(x.mint in headroom))headroom[x.mint]=x.mint===HOLLAR_ID?(await c.hollarMint(botEvm(d.bot),0n)).headroom
    :await c.fuseHeadroom(x.mint).catch(e=>{console.log('NO ROOM',x.mint,e.message);return 0n;});
   // tokens without an explicit cap refill to the level setup funded them at
   if(caps[d.bot]?.[x.held]===undefined&&!x.aToken&&isToken(x.held)){
    if(d.bot==='pools'&&(await api.query.omnipool.assets(x.held)).isSome)(caps.pools??={})[x.held]=toUnits((await api.call.currenciesApi.account(x.held,OMNIPOOL)).free.toBigInt()/20n,dec);
    if(d.bot==='replay')(caps.replay??={})[x.held]=toUnits((x.held===0?await api.query.balances.totalIssuance():await api.query.tokens.totalIssuance(x.held)).toBigInt()/100n,dec);
   }
  }
  const {plan,skipped}=planRefills({wanted,isToken,held,caps,decimals,headroom,last:lastRefills(r.testSeeds),now,minIntervalMs});
  console.log('REPORTS',wanted.map(d=>`${d.bot}:${d.asset}`).join(' ')||'none');
  for(const s of skipped)console.log('WAIT',s.bot,s.asset,s.reason);
  console.log('PLAN',json(plan));
  if(plan.length){
   const at=new Date(now).toISOString(),round=`refill-${at.slice(0,16).replace(/[-:]/g,'')}`,reports=wanted.map(d=>`${d.bot}:${d.asset}`);
   if(live){r.refills.push({round,plan,at,reports});save();}
   await seedRound(c,{round,plan,dryRunOnly:true,entry:{refill:true,at,reports}});
   if(live){r.refills.find(x=>x.round===round).done=true;save();}
   console.log(live?'REFILLED':'DRY RUN OK',round);
  }
 }
}finally{await c.api.disconnect();}
