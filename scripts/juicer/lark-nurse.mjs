// Lark only: keeps deposits open and exits settling from a pre-minted deployer
// HOLLAR stash. every top-up is a recorded test subsidy, never yield.
// Main cash above the active cohort's requirement is released to holders as a
// gift at the next checkpoint, so fills cover the gap plus a float of Main
// interest (--float seconds of it): enough for the keepers to see ready() and
// ramp, and it costs no more than refilling the exact gap every block would.
//   --mint=<hollar>   one governance mint into the stash, then exit
//   --watch=<s>       repeat passes; each pass reloads the journal
import assert from 'node:assert/strict';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {context,v,HOLLAR,POOL,deployer,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
// the next version checks underfunding off-chain and keeps a reserve for exit shortfalls
assert.ok(profile.legacy,`${profile.name}: no nurse or Main cushions on the next version`);
const arg=(name,fallback)=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1]??fallback;
const hollar=x=>BigInt(Math.round(Number(x)*1e6))*10n**12n,fmt=x=>Number((Number(x)/1e18).toFixed(4));
const GAP_MAX=hollar(arg('gap-max','2'));
const FILL_MAX=hollar(arg('fill-max','5')),TAIL_MAX=hollar(arg('tail-max','0.05')),TAIL_WAIT_S=Number(arg('tail-wait','600'));
const MINT=arg('mint'),WATCH_S=Number(arg('watch','0')),FLOAT_S=BigInt(arg('float','1800'));
const STATE='/tmp/lark-nurse-state.json';
const erc20=v.parseAbi(['function approve(address,uint256) returns(bool)','function transfer(address,uint256) returns(bool)']);
const ledger=v.parseAbi(['function fundPosition(uint256,uint256)']),vaultAbi=v.parseAbi(['function pokeSettle() returns(uint256)']);
const E10=10n**10n;
const max=(a,b)=>a>b?a:b,min=(a,b)=>a<b?a:b;

async function pass(){
 const c=await context();
 try{
  const {r,readSig,evmSend,save}=c;
  r.nurse??={stash:[]};r.testSubsidies??=[];
  const u=(a,f,args=[])=>readSig(a,`function ${f}(${args.map(()=> 'uint256').join(',')}) view returns(uint256)`,args);
  const balance=a=>readSig(HOLLAR,'function balanceOf(address) view returns(uint256)',[a]);
  if(MINT){
   const n=r.nurse.stash.length+1,amount=hollar(MINT),label=`deployer.mint-nurse-stash-${n}`;
   console.log('STASH before',fmt(await balance(deployer.address)),'mint',fmt(amount),label);
   await c.mintTestHollar(label,deployer.address,amount);
   if(live){r.nurse.stash.push({label,hollar:amount.toString(),ref:r.governance.find(g=>g.label===label)?.ref,at:new Date().toISOString(),note:'test HOLLAR stash; a subsidy only once transferred'});save();}
   console.log('STASH after',fmt(await balance(deployer.address)));
   return;
  }
  const state=existsSync(STATE)?JSON.parse(readFileSync(STATE,'utf8')):{tails:{}};
  const now=Math.floor(Date.now()/1000),actions=[];
  // a crashed action resumes with its recorded amount, never a recomputed one
  async function act(kind,amount,fields,send){
   r.nurse.pending??={kind,hollar:amount.toString(),label:`nurse-${kind}-${r.testSubsidies.filter(s=>s.kind===kind).length+1}`,...fields};save();
   const p=r.nurse.pending,value=BigInt(p.hollar);
   assert.ok(await balance(deployer.address)>=value,`stash too small for ${p.label}; run --mint`);
   const tx=await send(p,value);
   r.testSubsidies.push({...p,tx:r.calls.find(x=>x.label===tx&&x.evm)?.hash,at:new Date().toISOString()});delete r.nurse.pending;save();
   actions.push(`${p.label} ${fmt(value)}`);
  }
  const fundSource=(p,value)=>evmSend(`${p.label}.transfer`,HOLLAR,v.encodeFunctionData({abi:erc20,functionName:'transfer',args:[p.source,value]})).then(()=>`${p.label}.transfer`);
  const fundLedger=async(p,value)=>{
   await evmSend(`${p.label}.approve`,HOLLAR,v.encodeFunctionData({abi:erc20,functionName:'approve',args:[p.mainDebt,value]}));
   await evmSend(`${p.label}.fund`,p.mainDebt,v.encodeFunctionData({abi:ledger,functionName:'fundPosition',args:[BigInt(p.key),value]}));
   if(p.kind==='exit-tail')await evmSend(`${p.label}.settle`,p.vault,v.encodeFunctionData({abi:vaultAbi,functionName:'pokeSettle'}));
   return `${p.label}.fund`;
  };
  const sender={'source-fill':fundSource,cushion:fundLedger,'gap-fill':fundLedger,'exit-tail':fundLedger};
  if(r.nurse.pending&&live)await act(r.nurse.pending.kind,0n,{},sender[r.nurse.pending.kind]);

  // source: only lift it back to principal (negativeCarryBps gates every vault);
  // harvest pays everything above principal + reserve past threshold × principal
  const S=r.addresses.source;
  const readSource=async()=>{
   const [equity8,principal,unwind,reserve,threshold,negCarry,capacity]=await Promise.all(['totalEquity','principalEquity','unwindTargetEquity','executionCostReserve','harvestThreshold','negativeCarryBps','harvestCapacity'].map(f=>u(S,f)));
   const surplus=equity8*10n**10n-principal-unwind,trigger=reserve+principal*threshold/10n**18n;
   return {principal,surplus,reserve,trigger,room:trigger-surplus,negCarry,capacity};
  };
  let src=await readSource();
  const target=max(src.principal/20000n,hollar(0.05)),ceiling=src.trigger*7n/10n;
  if((src.surplus<0n||src.negCarry>0n)&&src.capacity===0n){
   const amount=min(min(target,ceiling)-src.surplus,FILL_MAX);
   if(amount>=hollar(0.01)&&live)await act('source-fill',amount,{source:S,reason:'ramp entry costs left the source near/below principal; filled below the harvest trigger',before:{surplus:src.surplus.toString(),trigger:src.trigger.toString(),principal:src.principal.toString()}},fundSource);
   else if(amount>=hollar(0.01))actions.push(`would source-fill ${fmt(amount)}`);
   src=await readSource();
  }

  // main interest accrues every block, PRIME equity only on oracle steps
  const borrowRate=(await readSig(POOL,'function getReserveData(address) view returns(uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)',[HOLLAR]))[4];
  const vaults={};
  for(const x of r.vaults){
   const md=x.mainDebt,ya=x.yieldAccounting;
   const read=async()=>{
    const [debt,funds,required,sv,eq,head,unwind,tail,pending,freed]=await Promise.all([u(md,'debtOf',[0n]),u(md,'activeFunds'),u(ya,'requiredSourceBacking'),u(ya,'sourceValue'),readSig(S,'function equityOf(address) view returns(uint256)',[x.address]),u(x.address,'queueHead'),u(x.address,'queueUnwind'),u(x.address,'queueTail'),readSig(S,'function pendingUnwindOf(address) view returns(uint256)',[x.address]),readSig(S,'function freedOf(address) view returns(uint256)',[x.address])]);
    const [underfunded,activeUnderfunded,ready,vaultDebt,owned,feeReserve,idle]=await Promise.all([readSig(x.address,'function isUnderfunded() view returns(bool)'),readSig(md,'function activeUnderfunded() view returns(bool)'),readSig(md,'function ready() view returns(bool)'),readSig(r.market.hollarDebt,'function balanceOf(address) view returns(uint256)',[x.address]),u(md,'ownedCash'),u(md,'sourceFeeReserve'),balance(x.address)]);
    // the active-cohort check and the vault-wide one in CompoundLogic.isUnderfunded
    const cohortGap=required-(eq*E10-sv),vaultGap=vaultDebt/E10*E10-(eq+(pending+idle)/E10+owned/E10-sv/E10-feeReserve/E10)*E10;
    return {debt,funds,headroom:-max(cohortGap,vaultGap),head,unwind,tail,pending,freed,underfunded,activeUnderfunded,ready};
   };
   let s=await read();
   // gap fill: the backing shortfall plus a float of interest, topped up before it runs dry
   const float=s.debt*borrowRate*FLOAT_S/(31536000n*10n**27n);
   if(s.debt>0n&&s.headroom<float/4n&&src.negCarry===0n){
    const gap=max(-s.headroom,0n),amount=((gap+float+max(gap/20n,10n**15n))/10n**12n+1n)*10n**12n;
    if(amount>GAP_MAX)actions.push(`${x.name} gap ${fmt(gap)} > gap max; not papering over it`);
    else if(live){await act('gap-fill',amount,{vault:x.address,mainDebt:md,key:'0',reason:'ramp/interest left the active cohort at or below its Main debt; gap plus an interest float',before:{gap:gap.toString(),funds:s.funds.toString()}},fundLedger);s=await read();}
    else actions.push(`would gap-fill ${x.name} ${fmt(amount)}`);
   }
   // exit tail: head started, source done, a sub-cent remainder unchanged for a while
   if(s.head<s.unwind){
    const q=await readSig(x.address,'function redemptions(uint256) view returns(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool)',[s.head]);
    const rem=q[3]-q[5],key=`${x.name}:${s.head}:${q[5]}`;
    if(rem>0n&&s.pending===0n&&s.freed===0n){
     state.tails[key]??=now;
     const [,,cash]=await readSig(md,'function positions(uint256) view returns(uint256,uint256,uint256,uint256,address)',[s.head+1n]);
     const need=max(rem,await u(md,'debtOf',[s.head+1n])-cash);
     const amount=((need*3n/2n+10n**15n)/10n**15n+1n)*10n**15n;
     if(now-state.tails[key]<TAIL_WAIT_S)actions.push(`${x.name} exit ${s.head} tail ${fmt(rem)} waiting ${now-state.tails[key]}s`);
     else if(amount>TAIL_MAX)actions.push(`${x.name} exit ${s.head} tail ${fmt(need)} above tail max; investigate`);
     else if(live){await act('exit-tail',amount,{vault:x.address,mainDebt:md,key:(s.head+1n).toString(),request:s.head.toString(),reason:'exit unwind cost left the FIFO head short',before:{remaining:rem.toString()}},fundLedger);s=await read();}
     else actions.push(`would fund ${x.name} exit ${s.head} with ${fmt(amount)}`);
    }
   }
   vaults[x.name]={underfunded:s.underfunded,ready:s.ready,headroom:fmt(s.headroom),cash:fmt(s.funds),debt:fmt(s.debt),queue:`${s.head}/${s.unwind}/${s.tail}`};
  }
  for(const k of Object.keys(state.tails))if(now-state.tails[k]>86400)delete state.tails[k];
  writeFileSync(STATE,JSON.stringify(state));
  const spent=r.testSubsidies.filter(s=>s.label?.startsWith('nurse-')).reduce((a,s)=>a+BigInt(s.hollar),0n);
  console.log(JSON.stringify({at:new Date().toISOString(),source:{surplus:fmt(src.surplus),reserve:fmt(src.reserve),trigger:fmt(src.trigger),room:fmt(src.room),negCarry:Number(src.negCarry)},vaults,stash:fmt(await balance(deployer.address)),nurseSubsidies:fmt(spent),actions}));
 }finally{await c.api.disconnect();}
}
do{
 try{await pass();}catch(e){console.log(JSON.stringify({at:new Date().toISOString(),error:String(e.message??e).split('\n')[0]}));if(!WATCH_S)process.exitCode=1;}
 if(WATCH_S)await new Promise(resolve=>setTimeout(resolve,WATCH_S*1000));
}while(WATCH_S);
// a failed context() leaves its websocket open
process.exit(process.exitCode??0);
