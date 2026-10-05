import assert from 'node:assert/strict';
import {context,testAccount,token,v,live} from './lark-context.mjs';
const c=await context();
try{
 assert.ok(live);const source=v.createPublicClient({transport:v.http('https://hdx.tarn.hydration.cloud',{timeout:30000})});
 const oracle='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
 const abi=v.parseAbi(['function getAssetPrice(address) view returns(uint256)','function getSourceOfAsset(address) view returns(address)','function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)']);
 const block=await source.getBlock();assert.ok(Date.now()/1000-Number(block.timestamp)<120);
 c.r.oracles??=[];
 for(const [id,name]of [[34,'ETH'],[1000765,'tBTC'],[43,'PRIME']]){
  if(c.r.oracles.some(o=>o.assetId===id))continue;
  const asset=token(id),price=await source.readContract({address:oracle,abi,functionName:'getAssetPrice',args:[asset],blockNumber:block.number});
  const feed=await source.readContract({address:oracle,abi,functionName:'getSourceOfAsset',args:[asset],blockNumber:block.number});
  const round=await source.readContract({address:feed,abi,functionName:'latestRoundData',blockNumber:block.number});
  assert.ok(price>0n&&round[3]>0n&&round[3]<=block.timestamp&&block.timestamp-round[3]<86400n,'stale reference');
  const address=await c.deploy('ManagedOracle',[`Lark testnet ${name}: mainnet MM mirror`,1n,testAccount(19).address,price],`LarkOracle.${name}`);
  c.r.oracles.push({assetId:id,asset,name,address,sourceFeed:feed,sourcePrice:price,sourceUpdatedAt:round[3],sourceBlock:block.number,sourceBlockHash:block.hash});c.save();
 }
 c.r.status='testnet-mirrors-deployed-not-installed';c.save();
}finally{await c.api.disconnect()}
