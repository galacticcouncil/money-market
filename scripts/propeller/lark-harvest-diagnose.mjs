// Read-only eth_call diagnostics. Overrides never change live Lark policy.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {requirePins,CORE_FILE as FILE,GENESIS} from './lark-pins.mjs';
import {artifact} from './native-artifacts.mjs';
const v=createRequire(import.meta.url)('viem');
const r=JSON.parse(readFileSync(FILE,'utf8'));
const pub=v.createPublicClient({transport:v.http(requirePins().rpc,{timeout:60000}),cacheTime:0});
assert.equal(await pub.request({method:'chain_getBlockHash',params:[0]}),r.genesis);
assert.equal(r.genesis,GENESIS);
const block=await pub.getBlockNumber({cacheTime:0});
const layout=JSON.parse(readFileSync('/tmp/propeller-lark-vault-layout.json','utf8')).storage;
const controller=JSON.parse(readFileSync('/tmp/propeller-lark-controller-layout.json','utf8')).storage;
const slot=layout.find(x=>x.label==='compoundSlippageBps');
const capSlot=controller.find(x=>x.label==='maxShortfallBps');
assert.equal(slot.offset,20);
const overrides=[];
for(const vault of r.vaults){
 const old=BigInt(await pub.getStorageAt({address:vault.address,slot:v.toHex(BigInt(slot.slot),{size:32}),blockNumber:block}));
 const mask=65535n<<160n,value=(old&~mask)|(5000n<<160n);
 overrides.push({address:vault.address,stateDiff:[{slot:v.toHex(BigInt(slot.slot),{size:32}),value:v.toHex(value,{size:32})}]});
}
const diffs=r.executionPolicy.limits.filter(l=>l.consumer.toLowerCase()!==r.addresses.source.toLowerCase()).map(l=>({slot:v.keccak256(v.encodeAbiParameters([{type:'bytes32'},{type:'uint256'}],[l.lane,BigInt(capSlot.slot)])),value:v.toHex(5000n,{size:32})}));
overrides.push({address:r.addresses.controller,stateDiff:diffs});
const options={address:r.addresses.controller,abi:artifact('ExecutionController').abi,functionName:'preview',args:[r.addresses.harvester,v.encodeFunctionData({abi:artifact('Harvester').abi,functionName:'harvest',args:[[]]})],account:r.testSigners.keeper,blockNumber:block,gas:16777216n};
const result={block,readOnly:true,livePolicyUnchanged:true};
const limitsSlot=controller.find(x=>x.label==='limits');
const minimumDiffs=[];
for(const lane of r.executionPolicy.limits.filter(l=>r.vaults.some(w=>w.mainDebt.toLowerCase()===l.consumer.toLowerCase()))){
 const base=BigInt(v.keccak256(v.encodeAbiParameters([{type:'bytes32'},{type:'uint256'}],[lane.lane,BigInt(limitsSlot.slot)])))+1n;
 const word=BigInt(await pub.getStorageAt({address:r.addresses.controller,slot:v.toHex(base,{size:32}),blockNumber:block}));
 minimumDiffs.push({slot:v.toHex(base,{size:32}),value:v.toHex((word>>128n<<128n)|1n,{size:32})});
}
const loweredMinimums=[...overrides.slice(0,-1),{address:r.addresses.controller,stateDiff:[...diffs,...minimumDiffs]}];
for(const [name,stateOverride]of [['live',[]],['diagnosticPriceFloorsOnly',overrides],['diagnosticFloorsAndServiceMinimums',loweredMinimums]]){
 try{result[name]=(await pub.simulateContract({...options,stateOverride})).result;}
 catch(e){result[name]={error:e.shortMessage,details:e.details,causes:[]};for(let c=e;c;c=c.cause)if(c.data)result[name].causes.push(c.data);}
}
try{
 result.trace=await pub.request({method:'debug_traceCall',params:[{from:r.testSigners.keeper,to:options.address,data:v.encodeFunctionData(options),gas:v.toHex(options.gas)},v.toHex(block),{tracer:'callTracer'}]});
}catch(e){result.traceUnavailable=e.shortMessage??e.message;}
const json=JSON.stringify(result,(_,x)=>typeof x==='bigint'?x.toString():x,2)+'\n';
writeFileSync('/tmp/propeller-lark-harvest-diagnosis.json',json);console.log(JSON.stringify({...result,trace:result.trace?'saved to evidence file':undefined},(_,x)=>typeof x==='bigint'?x.toString():x,2));
