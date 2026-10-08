// Lark only: plans market-bot inventory refills from what the bots report missing. Pure;
// lark-refill-bots.mjs reads the reports, balances and fuses and submits the plan through
// the seed mechanism.
const HUB=1,HOLLAR=222;
// aTokens a bot holds: refilled by minting the underlying and supplying it as the bot
export const ATOKENS={1001:5,1002:10,1003:22,1006:1000765,1007:34,1009:1000752,1043:43,1044:44};
// pools wraps these itself from an underlying stash, so its refill tops up the stash
export const POOL_STASH={1001:5,9001:40,420:1000809};
// top-up ceilings in units of the held asset. pools omnipool tokens and replay tokens without
// an entry get the setup levels instead: 5% of the omnipool reserve, 1% of issuance
export const CAPS={
 markets:{43:300000,222:60000},
 pools:{222:200000,22:50000,5:100000,40:200,1000809:15,1002:29500,1003:26300,1007:0.5,1044:20800,1009:380},
 replay:{222:200000,1001:20000,1002:150000,1003:300000,1006:0.5},
};
// bot log rows asking for inventory: `inventory-refill-needed`, and replay's skipped inputs.
// docker and swarm prefixes before the json are ignored
export function parseReports(text,{since=0}={}){
 const out=[];
 for(const line of text.split('\n')){
  const start=line.indexOf('{');if(start<0)continue;
  let row;try{row=JSON.parse(line.slice(start));}catch{continue;}
  const time=Date.parse(row.time);
  if(!(time>=since))continue;
  if(row.name==='inventory-refill-needed'&&row.mode&&row.asset!==undefined)out.push({bot:row.mode,asset:Number(row.asset),time});
  else if(row.name==='replay-window'&&row.mode==='replay')for(const id of row.skippedInputs??[])out.push({bot:'replay',asset:Number(id),time});
 }
 return out;
}
// one demand per bot and asset, the latest report
export function demands(reports){
 const latest=new Map();
 for(const r of reports){const key=`${r.bot}:${r.asset}`;if(!(latest.get(key)?.time>=r.time))latest.set(key,r);}
 return [...latest.values()].sort((a,b)=>a.bot.localeCompare(b.bot)||a.asset-b.asset);
}
// what a report asks to refill: the asset whose balance is capped, what is minted, what it is supplied into
export function recipe(bot,asset,isToken){
 if(asset===HUB)return null;
 if(asset===HOLLAR)return {held:HOLLAR,mint:HOLLAR};
 if(bot==='pools'&&POOL_STASH[asset])return {held:POOL_STASH[asset],mint:POOL_STASH[asset]};
 if(ATOKENS[asset])return {held:asset,mint:ATOKENS[asset],aToken:asset};
 return isToken(asset)?{held:asset,mint:asset}:null;
}
export const toUnits=(raw,d)=>Number(raw*1000000n/10n**BigInt(d))/1e6;
export const fromUnits=(n,d)=>BigInt(Math.round(n*1e6))*10n**BigInt(d)/1000000n;
// [bot, asset to mint, units, aToken] items for the seed mechanism, and why the rest wait.
// held: raw balance by `${bot}:${asset}`; caps: units by bot and asset; headroom: raw room by
// minted asset (deposit fuse, or the facilitator for HOLLAR; null when unbounded); last: ms
// of the previous refill by `${bot}:${asset}`
export function planRefills({wanted,isToken,held,caps,decimals,headroom={},last={},now,minIntervalMs}){
 const plan=[],skipped=[],used={},seen=new Set();
 const skip=(d,reason)=>skipped.push({bot:d.bot,asset:d.asset,reason});
 for(const d of wanted){
  const r=recipe(d.bot,d.asset,isToken);
  if(!r){skip(d,'not mintable here; seed it by hand');continue;}
  // aDOT and its DOT stash are one refill for pools
  const key=`${d.bot}:${r.held}`;if(seen.has(key))continue;seen.add(key);
  const cap=caps[d.bot]?.[r.held];
  if(cap===undefined){skip(d,`no cap for ${r.held}; seed it by hand`);continue;}
  if(last[key]!==undefined&&now-last[key]<minIntervalMs){skip(d,`refilled ${Math.round((now-last[key])/60000)} min ago`);continue;}
  const dec=decimals[r.mint],ceiling=fromUnits(cap,dec),have=held[key]??0n;
  if(have*2n>=ceiling){skip(d,'holds half its cap or more');continue;}
  let amount=ceiling-have;
  const room=headroom[r.mint];
  if(room!==null&&room!==undefined){
   // a tenth of the room stays free for whatever else mints in the same window
   const free=room*9n/10n-(used[r.mint]??0n);
   if(free*10n<amount){skip(d,`room for ${r.mint} (${room}) is under a tenth of the refill`);continue;}
   if(amount>free)amount=free;
  }
  const n=toUnits(amount,dec);
  if(n<=0){skip(d,'dust');continue;}
  used[r.mint]=(used[r.mint]??0n)+fromUnits(n,dec);
  plan.push([d.bot,r.mint,n,...(r.aToken?[r.aToken]:[])]);
 }
 return {plan,skipped};
}
// when each bot/asset was last refilled, from the journal's refill rounds
export function lastRefills(testSeeds=[]){
 const last={};
 for(const s of testSeeds)if(s.refill&&s.at)for(const p of s.plan)last[`${p.bot}:${p.suppliedAs??p.asset}`]=Math.max(last[`${p.bot}:${p.suppliedAs??p.asset}`]??0,Date.parse(s.at));
 return last;
}
