// Read-only evidence capture for the October Lark rehearsal.
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
import {artifact} from './native-artifacts.mjs';
const require=createRequire(import.meta.url),v=require('viem');
import {FILE,GENESIS} from './lark-pins.mjs';
const r=JSON.parse(readFileSync(FILE,'utf8'));
assert.equal(r.genesis,GENESIS);
const pub=v.createPublicClient({transport:v.http('https://node4.lark.hydration.cloud',{timeout:60000}),cacheTime:0});
assert.equal(await pub.getChainId(),222222);
assert.equal(await pub.request({method:'chain_getBlockHash',params:[0]}),r.genesis);
const blockNumber=await pub.getBlockNumber({cacheTime:0}),block=await pub.getBlock({blockNumber});
assert.ok(Math.abs(Date.now()/1000-Number(block.timestamp))<120,'stale head');
const out={time:new Date().toISOString(),genesis:r.genesis,block:blockNumber,blockHash:block.hash,source:{},vaults:[],receipts:[]};
const read=(name,address,functionName,args=[])=>pub.readContract({address,abi:artifact(name).abi,functionName,args,blockNumber});
for(const method of ['healthFactor','targetHf','totalEquity','principalEquity','totalShares','harvestThreshold','harvestCapacity','executionCostReserve','unwindTargetEquity','deleverDebtTarget','negativeCarryBps'])out.source[method]=await read('SubLoop',r.addresses.source,method);
out.harvestable=await read('Harvester',r.addresses.harvester,'harvestable');
for(const vault of r.vaults){
 const row={name:vault.name,address:vault.address};
 for(const method of ['totalAssets','reinvestAssets','loopShares','queueHead','queueTail','queueUnwind'])row[method]=await read('CollateralVault',vault.address,method);
 const ledger=await read('CollateralVault',vault.address,'mainDebt');
 row.mainReady=await read('PropellerMainDebt',ledger,'ready');
 row.mainInterest=await read('PropellerMainDebt',ledger,'interestOf',[0n]);
 row.pendingUnwind=await read('SubLoop',r.addresses.source,'pendingUnwindOf',[vault.address]);
 row.redemptions=[];
 for(const request of r.checks.hostedExits??[])if(request.vault===vault.address)row.redemptions.push({id:request.id,state:await read('CollateralVault',vault.address,'redemptions',[BigInt(request.id)])});
 row.eligibleHarvest=await pub.simulateContract({address:vault.address,abi:artifact('CollateralVault').abi,functionName:'prepareHarvest',account:r.addresses.harvester,blockNumber}).then(x=>x.result).catch(e=>({error:e.shortMessage}));
 out.vaults.push(row);
}
try{
 out.harvestPreview=(await pub.simulateContract({address:r.addresses.controller,abi:artifact('ExecutionController').abi,functionName:'preview',args:[r.addresses.harvester,v.encodeFunctionData({abi:artifact('Harvester').abi,functionName:'harvest',args:[[]]})],account:r.testSigners.keeper,blockNumber,gas:16777216n})).result;
}catch(e){out.harvestPreview={error:e.shortMessage,details:e.details,causes:[]};for(let c=e;c;c=c.cause)out.harvestPreview.causes.push({name:c.name,data:c.data,reason:c.reason});}
try{
 out.repayPreview=(await pub.simulateContract({address:r.addresses.controller,abi:[...artifact('ExecutionController').abi,...artifact('SubLoop').abi],functionName:'preview',args:[r.addresses.source,v.encodeFunctionData({abi:artifact('SubLoop').abi,functionName:'pokeRepay'})],account:r.testSigners.keeper,blockNumber,gas:16777216n})).result;
}catch(e){out.repayPreview={error:e.shortMessage,details:e.details};}
for(const hash of process.argv.slice(2)){
 assert.match(hash,/^0x[0-9a-f]{64}$/);
 const receipt=await pub.getTransactionReceipt({hash});
 out.receipts.push({hash,status:receipt.status,block:receipt.blockNumber,from:receipt.from,to:receipt.to,gasUsed:receipt.gasUsed,events:receipt.logs.map(log=>{
  for(const name of ['ExecutionController','SubLoop','CollateralVault','Harvester'])try{const event=v.decodeEventLog({abi:artifact(name).abi,data:log.data,topics:log.topics});return {address:log.address,name:event.eventName,args:event.args};}catch{}
  return null;
 }).filter(Boolean)});
}
const json=JSON.stringify(out,(_,x)=>typeof x==='bigint'?x.toString():x,2)+'\n';
const file=process.env.PROPELLER_OBSERVATION_FILE??'/tmp/propeller-lark-observation.json';
writeFileSync(file,json);console.log(json);
