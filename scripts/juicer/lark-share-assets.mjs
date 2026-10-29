// The vault shares (jETH, jBTC) as sufficient Erc20 assets at the ids after the synthetic's.
// The existential deposit is the collateral's.
import assert from 'node:assert/strict';
import {context,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
assert.ok(!profile.legacy,`${profile.name} runs the #62 shares; pass the new lark's --profile`);
const c=await context();
try{
 const {r,api,readSig,enact,save}=c;
 assert.ok(r.governance.find(g=>g.label==='bind-execution-controller')?.verified&&r.synthAssetId,'finish core wiring first');
 const loc=key=>({parents:0,interior:{X1:[{AccountKey20:{network:null,key}}]}});
 const shares=[];
 for(const [i,x]of r.vaults.entries()){
  const [name,symbol]=profile.names.vaults[x.name];
  assert.equal(await readSig(x.address,'function name() view returns(string)'),name);
  assert.equal(await readSig(x.address,'function symbol() view returns(string)'),symbol);
  shares.push({vault:x,name,symbol,id:r.synthAssetId+1+i,decimals:await readSig(x.address,'function decimals() view returns(uint8)')});
 }
 const registered=async s=>{
  const at=await api.query.assetRegistry.locationAssets(loc(s.vault.address));
  return at.isSome?{id:at.unwrap().toNumber(),detail:(await api.query.assetRegistry.assets(at.unwrap())).unwrap()}:null;
 };
 const calls=[];
 for(const s of shares){
  const at=await registered(s);
  if(at){
   assert.equal(at.detail.assetType.toString(),'Erc20',`${s.symbol} is already asset ${at.id}`);
   if(!at.detail.isSufficient.isTrue)calls.push(api.tx.assetRegistry.update(at.id,null,null,null,null,true,null,null,null));
   continue;
  }
  assert.ok((await api.query.assetRegistry.assets(s.id)).isNone,`asset id ${s.id} is taken`);
  assert.ok((await api.query.assetRegistry.assetIds(s.name)).isNone,`asset name ${s.name} is taken`);
  const ed=(await api.query.assetRegistry.assets(s.vault.assetId)).unwrap().existentialDeposit.toString();
  calls.push(api.tx.assetRegistry.register(s.id,s.name,'Erc20',ed,s.symbol,s.decimals,loc(s.vault.address),null,true));
 }
 if(calls.length)await enact('register-share-assets',calls);
 if(live){
  const assets={};
  for(const s of shares){
   const at=await registered(s);
   assert.ok(at?.detail.assetType.toString()==='Erc20'&&at.detail.isSufficient.isTrue,`${s.symbol} is not a sufficient Erc20 asset`);
   assert.equal(at.detail.decimals.unwrap().toNumber(),s.decimals);
   assets[s.symbol]=at.id;
  }
  r.checks.shareAssets=assets;save();
  console.log('SHARE ASSETS',JSON.stringify(assets));
 }
}finally{await c.api.disconnect();}
