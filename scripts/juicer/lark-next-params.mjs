// Next-version parameters on a new Lark: harvest threshold 2e14 (~0.02% of principal) and a
// 1,000 HOLLAR protocol reserve per vault, which governance funds from the test facilitator; then
// the launch economics: rebalance bands, protocol fee and the Main and loop discounts. pool 143's
// fee comes from lark-prime-pool.mjs, PRIME lanes from lark-prime-throughput.mjs. Lark 4 keeps its own.
import assert from 'node:assert/strict';
import {context,artifact,v,GOV,HOLLAR,POOL,live} from './lark-context.mjs';
import {profile,NEXT_PARAMS,bandGaps} from './lark-pins.mjs';
const THRESHOLD=NEXT_PARAMS.harvestThreshold,RESERVE=NEXT_PARAMS.reserve,LABEL='next-version-parameters';
const {band:BAND,revenue:REVENUE}=NEXT_PARAMS,ECONOMICS='next-version-economics';
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
 const discount=r.addresses.discount,fees=r.addresses.fees;
 assert.ok(discount&&fees,'run the market step first: the discount is installed there');
 const maxLtv=async x=>Number(await readSig(POOL,'function getConfiguration(address) view returns(uint256)',[x.asset])&0xffffn);
 const gapsOf=async x=>{const [target,relever,delever]=await read('SubLoop',source,'rebalanceBand',[x.address]);return {target:Number(target),relever:Number(relever),delever:Number(delever)};};
 const same=(a,b)=>a.target===b.target&&a.relever===b.relever&&a.delever===b.delever;
 if(!r.governance.find(g=>g.label===ECONOMICS)?.verified){
  assert.equal((await read('JuicerDiscount',discount,'loop')).toLowerCase(),source.toLowerCase(),'the loop is not enrolled in the discount');
  const econ=[];
  for(const x of r.vaults){
   const want=bandGaps(await maxLtv(x),BAND);
   if(!same(await gapsOf(x),want))econ.push(govEvm(source,artifact('SubLoop').abi,'setRebalanceBand',[x.address,want.target,want.relever,want.delever],500000));
   if(Number(await read('JuicerFeeController',fees,'protocolFeeBps',[x.address]))!==REVENUE.protocolFeeBps){
    econ.push(govEvm(fees,artifact('JuicerFeeController').abi,'setProtocolFeeBps',[x.address,REVENUE.protocolFeeBps],500000));
   }
  }
  // each refreshes the enrolled vaults' or the loop's cached HOLLAR discount on the debt token
  if(Number(await read('JuicerDiscount',discount,'discountBps'))!==REVENUE.mainDiscountBps){
   econ.push(govEvm(discount,artifact('JuicerDiscount').abi,'setDiscountBps',[REVENUE.mainDiscountBps],1500000));
  }
  if(Number(await read('JuicerDiscount',discount,'loopDiscountBps'))!==REVENUE.loopDiscountBps){
   econ.push(govEvm(discount,artifact('JuicerDiscount').abi,'setLoopDiscountBps',[REVENUE.loopDiscountBps],1000000));
  }
  if(econ.length)await enact(ECONOMICS,econ);
 }
 if(live){
  assert.equal(await read('SubLoop',source,'harvestThreshold'),THRESHOLD);
  const reserves={};
  for(const x of r.vaults){reserves[x.name]=(await reserveOf(x)).toString();assert.ok(BigInt(reserves[x.name])>=RESERVE,`${x.name} protocol reserve short`);}
  const bands={},feeBps={};
  for(const x of r.vaults){
   const want=bandGaps(await maxLtv(x),BAND),got=await gapsOf(x);
   assert.ok(same(got,want),`${x.name} band ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
   bands[x.name]=got;
   feeBps[x.name]=Number(await read('JuicerFeeController',fees,'protocolFeeBps',[x.address]));
   assert.equal(feeBps[x.name],REVENUE.protocolFeeBps,`${x.name} protocol fee`);
  }
  const mainBps=Number(await read('JuicerDiscount',discount,'discountBps')),loopBps=Number(await read('JuicerDiscount',discount,'loopDiscountBps'));
  assert.deepEqual([mainBps,loopBps],[REVENUE.mainDiscountBps,REVENUE.loopDiscountBps],'discount rates');
  const loopCap=await read('JuicerDiscount',discount,'loopCap');
  r.discountBps=mainBps;
  r.checks.nextParameters={harvestThreshold:THRESHOLD.toString(),protocolReserve:reserves,band:BAND,bands,protocolFeeBps:feeBps,
   discount:{mainBps,loopBps,loopCap:loopCap.toString()},note:'protocol reserve is test HOLLAR from the facilitator; not yield'};save();
  console.log('PARAMETERS',JSON.stringify(r.checks.nextParameters));
 }
}finally{await c.api.disconnect();}
