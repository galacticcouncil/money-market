import assert from 'node:assert/strict';
import {context} from './lark-context.mjs';
const c=await context();
try{
 for(const vault of c.r.vaults){
  const tail=await c.read('CollateralVault',vault.address,'queueTail');
  if(tail===0n){console.log('NO REQUEST',vault.name);continue;}
  const eligible=await c.read('CollateralVault',vault.address,'unwindEligibleAt',[0n]);
  const now=BigInt((await c.api.query.timestamp.now()).toString())/1000n;
  assert.ok(now>=eligible,`${vault.name}: withdrawal cooldown still active`);
  assert.equal(await c.readSig(c.r.market.hollarDebt,'function balanceOf(address) view returns(uint256)',[vault.address]),0n);
  await c.write(`ui.${vault.name}.startUnwinds.0`,'CollateralVault',vault.address,'startUnwinds',[1n]);
  await c.write(`ui.${vault.name}.pokeSettle.0`,'CollateralVault',vault.address,'pokeSettle');
  const row=await c.read('CollateralVault',vault.address,'redemptions',[0n]);
  assert.ok(row[6]>0n,'no collateral made claimable');assert.equal(row[3],0n);
  console.log('UI CLAIMABLE',vault.name,row[6].toString());
 }
}finally{await c.api.disconnect();}
