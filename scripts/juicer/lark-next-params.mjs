// Next-version parameters on a new Lark: harvest threshold 2e14 (~0.02% of principal) and a
// 1,000 HOLLAR protocol reserve per vault, which governance funds from the test facilitator.
// PRIME lanes at 1,000 a trade come from lark-prime-throughput.mjs. Lark 4 keeps its own.
import assert from 'node:assert/strict';
import {context,artifact,v,GOV,HOLLAR,live} from './lark-context.mjs';
import {profile,NEXT_PARAMS} from './lark-pins.mjs';
const THRESHOLD=NEXT_PARAMS.harvestThreshold,RESERVE=NEXT_PARAMS.reserve,LABEL='next-version-parameters';
assert.ok(!profile.legacy,`${profile.name} keeps the parameters of its #62 contracts`);
const c=await context();
try{
 const {r,read,readSig,govEvm,enact,save}=c,source=r.addresses.source;
 assert.ok(r.governance.find(g=>g.label==='bind-execution-controller')?.verified,'finish core wiring first');
 const reserveOf=x=>readSig(x.mainDebt,'function protocolReserve() view returns(uint256)');
 const calls=[];
 if(!r.governance.find(g=>g.label===LABEL)?.verified){
  // setParams rewrites all four; the other three keep their live values
  const [targetHf,floor,trigger,threshold]=await Promise.all(['targetHf','deployHfFloor','deLeverTrigger','harvestThreshold'].map(f=>read('SubLoop',source,f)));
  if(threshold!==THRESHOLD)calls.push(govEvm(source,artifact('SubLoop').abi,'setParams',[targetHf,floor,trigger,THRESHOLD],500000));
  const short=[];
  for(const x of r.vaults){const held=await reserveOf(x);if(held<RESERVE)short.push([x,RESERVE-held]);}
  if(short.length){
   const total=short.reduce((a,[,n])=>a+n,0n),mint=await c.hollarMint(GOV,total);
   assert.ok(total<=mint.headroom,`HOLLAR facilitator headroom ${mint.headroom} is short of ${total}`);
   const erc20=v.parseAbi(['function approve(address,uint256) returns(bool)']),ledger=v.parseAbi(['function fundReserve(uint256)']);
   calls.push(...mint.calls,...short.flatMap(([x,n])=>[govEvm(HOLLAR,erc20,'approve',[x.mainDebt,n],500000),govEvm(x.mainDebt,ledger,'fundReserve',[n],500000)]));
  }
  if(calls.length)await enact(LABEL,calls);
 }
 if(live){
  assert.equal(await read('SubLoop',source,'harvestThreshold'),THRESHOLD);
  const reserves={};
  for(const x of r.vaults){reserves[x.name]=(await reserveOf(x)).toString();assert.ok(BigInt(reserves[x.name])>=RESERVE,`${x.name} protocol reserve short`);}
  r.checks.nextParameters={harvestThreshold:THRESHOLD.toString(),protocolReserve:reserves,note:'protocol reserve is test HOLLAR from the facilitator; not yield'};save();
  console.log('PARAMETERS',JSON.stringify(r.checks.nextParameters));
 }
}finally{await c.api.disconnect();}
