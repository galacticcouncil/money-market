// The vault's DEPOSIT_GUARDIAN_ROLE for both keeper signers and nothing else. It gates only
// setDeficitStop, so a keeper can stop deposits on a deficit and lift its own stop;
// pauseDeposits and pause stay with governance.
import assert from 'node:assert/strict';
import {context,artifact,live} from './lark-context.mjs';
const vaultAbi=artifact('CollateralVault').abi;
assert.ok(vaultAbi.some(x=>x.name==='DEPOSIT_GUARDIAN_ROLE'),'no DEPOSIT_GUARDIAN_ROLE in these artifacts: point PROPELLER_ARTIFACT_DIR at the next-version build');
const c=await context();
try{
 const {r,read,govEvm,enact,save}=c;
 const keepers=[r.testSigners.keeper,r.testSigners.keeperSecondary];
 assert.ok(keepers.every(Boolean),'keeper signers missing from the journal; run lark-market-setup.mjs first');
 const missing=async()=>{
  const out=[];
  for(const x of r.vaults){
   const role=await read('CollateralVault',x.address,'DEPOSIT_GUARDIAN_ROLE');
   for(const keeper of keepers)if(!await read('CollateralVault',x.address,'hasRole',[role,keeper]))out.push([x,role,keeper]);
  }
  return out;
 };
 const grants=await missing();
 if(grants.length)await enact('deposit-guardian-keepers',grants.map(([x,role,keeper])=>govEvm(x.address,vaultAbi,'grantRole',[role,keeper],500000)));
 if(live){assert.equal((await missing()).length,0,'deposit guardian not granted');r.checks.depositGuardian={keepers,vaults:r.vaults.map(x=>x.address)};save();}
}finally{await c.api.disconnect();}
