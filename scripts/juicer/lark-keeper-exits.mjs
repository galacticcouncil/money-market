// Request small exits from our public fixture account; hosted keepers do all
// unwind/settlement work. Never touches another depositor's shares.
import assert from 'node:assert/strict';
import {context,deployer,live} from './lark-context.mjs';
const c=await context();
try{
 assert.ok(live,'--live required');
 c.r.checks.hostedExits??=[];
 for(const vault of c.r.vaults){
  let record=c.r.checks.hostedExits.find(x=>x.vault===vault.address);
  if(!record){
   const shares=vault.assetId===34?10n**15n:10n**13n;
   assert.ok(await c.read('CollateralVault',vault.address,'balanceOf',[deployer.address])>=shares);
   const id=await c.read('CollateralVault',vault.address,'queueTail');
   record={vault:vault.address,name:vault.name,id:id.toString(),shares:shares.toString(),owner:deployer.address};
   c.r.checks.hostedExits.push(record);c.save();
  }
  await c.write(`hosted-exit.${vault.name}.request`,'CollateralVault',vault.address,'requestRedeem',[BigInt(record.shares),deployer.address]);
  console.log('REQUESTED',record.name,record.id,record.shares);
 }
}finally{await c.api.disconnect();}
