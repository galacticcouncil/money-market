import assert from 'node:assert/strict';
import {context,testAccount,token,v,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const priced=[...Object.values(profile.collateral).map(x=>[x.assetId,x.symbol,x.mirror!==false]),[43,'PRIME',true]];
const c=await context();
try{
 assert.ok(live);const source=v.createPublicClient({transport:v.http('https://hdx.tarn.hydration.cloud',{timeout:30000})});
 const oracle='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
 const abi=v.parseAbi(['function getAssetPrice(address) view returns(uint256)','function getSourceOfAsset(address) view returns(address)','function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)']);
 const block=await source.getBlock();assert.ok(Date.now()/1000-Number(block.timestamp)<120);
 c.r.oracles??=[];
 for(const [id,name,mirror]of priced){
  if(c.r.oracles.some(o=>o.assetId===id))continue;
  const asset=token(id);
  // a collateral that keeps its forked source gets a row naming that source, and no mirror
  if(!mirror){
   const address=await c.readSig(oracle,'function getSourceOfAsset(address) view returns(address)',[asset]);
   assert.notEqual(address,v.zeroAddress,`${name} has no oracle source`);
   assert.ok(await c.readSig(oracle,'function getAssetPrice(address) view returns(uint256)',[asset])>0n,`${name} has no price`);
   c.r.oracles.push({assetId:id,asset,name,address,mirror:false});c.save();
   continue;
  }
  const price=await source.readContract({address:oracle,abi,functionName:'getAssetPrice',args:[asset],blockNumber:block.number});
  const feed=await source.readContract({address:oracle,abi,functionName:'getSourceOfAsset',args:[asset],blockNumber:block.number});
  const round=await source.readContract({address:feed,abi,functionName:'latestRoundData',blockNumber:block.number});
  assert.ok(price>0n&&round[3]>0n&&round[3]<=block.timestamp&&block.timestamp-round[3]<86400n,'stale reference');
  const address=await c.deploy('ManagedOracle',[`Lark testnet ${name}: mainnet MM mirror`,1n,testAccount(19).address,price],`LarkOracle.${name}`);
  c.r.oracles.push({assetId:id,asset,name,address,sourceFeed:feed,sourcePrice:price,sourceUpdatedAt:round[3],sourceBlock:block.number,sourceBlockHash:block.hash});c.save();
 }
 c.r.status='testnet-mirrors-deployed-not-installed';c.save();
}finally{await c.api.disconnect()}
