// The launch manifest, and juicer.ts's plan once there is one, into the lark journal (lark-launch.mjs).
//   node lark-launch-adopt.mjs <manifest.json> [plan.json]
import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import {context,v,POOL} from './lark-context.mjs';
import {adoptLaunch} from './lark-launch.mjs';
const [manifestFile,planFile]=process.argv.slice(2).filter(a=>!a.startsWith('--'));
assert.ok(manifestFile,'usage: lark-launch-adopt.mjs <manifest.json> [plan.json]');
const c=await context();
try{
 const {r,pub,save}=c,read=f=>JSON.parse(readFileSync(f,'utf8'));
 adoptLaunch(r,read(manifestFile),planFile&&existsSync(planFile)?read(planFile):undefined);
 Object.assign(r.launch,{manifest:manifestFile,...(planFile?{plan:planFile}:{})});
 const abi=v.parseAbi(['function getReserveData(address) view returns ((uint256 configuration,uint128 liquidityIndex,uint128 liquidityRate,uint128 borrowIndex,uint128 borrowRate,uint128 stableRate,uint40 updatedAt,uint16 id,address aToken,address stableDebt,address variableDebt,address strategy,uint128 accrued,uint128 unbacked,uint128 isolationDebt))']);
 const listed=(await pub.readContract({address:POOL,abi,functionName:'getReserveData',args:[r.addresses.synth]})).aToken;
 if(listed!==v.zeroAddress)r.addresses.aSynthetic=listed;
 r.status=listed===v.zeroAddress?'launch-deployed-awaiting-the-referendum':'launch-enacted';save();
 console.log('ADOPTED',JSON.stringify({source:r.addresses.source,vaults:r.vaults.map(x=>x.address),aSynthetic:r.addresses.aSynthetic??null,policy:!!r.executionPolicy}));
}finally{await c.api.disconnect();}
