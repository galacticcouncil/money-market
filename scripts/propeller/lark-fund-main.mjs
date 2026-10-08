// Explicit test recovery funding for each active Main cohort, so tiny entry-cost
// gaps do not freeze deposits on Lark. Recorded as a subsidy, never as yield.
import assert from 'node:assert/strict';
import {context,v,HOLLAR,deployer,live} from './lark-context.mjs';
const AMOUNT=10n**18n;
const c=await context();
try{
 const {r,read,readSig,evmSend,save}=c;
 assert.ok(live,'--live required');
 r.testSubsidies??=[];
 const need=r.vaults.filter(x=>!r.testSubsidies.some(s=>s.vault===x.address));
 if(need.length&&await readSig(HOLLAR,'function balanceOf(address) view returns(uint256)',[deployer.address])<AMOUNT*BigInt(need.length))
  await c.mintTestHollar(`deployer.mint-recovery-hollar-${need.length}`,deployer.address,AMOUNT*BigInt(need.length));
 const erc20=v.parseAbi(['function approve(address,uint256) returns(bool)']),ledger=v.parseAbi(['function fundPosition(uint256,uint256)']);
 for(const vault of need){
  await evmSend(`recovery.${vault.name}.approve`,HOLLAR,v.encodeFunctionData({abi:erc20,functionName:'approve',args:[vault.mainDebt,AMOUNT]}));
  await evmSend(`recovery.${vault.name}.fund`,vault.mainDebt,v.encodeFunctionData({abi:ledger,functionName:'fundPosition',args:[0n,AMOUNT]}));
  r.testSubsidies.push({vault:vault.address,mainDebt:vault.mainDebt,hollar:AMOUNT.toString(),reason:'entry-cost gap after deferred deployment'});save();
 }
 // the source itself starts below its principal by the entry swaps' cost; idle
 // HOLLAR counts as source equity, so recapitalize that gap plus ramp headroom
 const SOURCE=5n*10n**17n;
 if(!r.testSubsidies.some(s=>s.source)){
  if(await readSig(HOLLAR,'function balanceOf(address) view returns(uint256)',[deployer.address])<SOURCE)await c.mintTestHollar('deployer.mint-source-recap-hollar',deployer.address,SOURCE);
  await evmSend('recovery.source.transfer',HOLLAR,v.encodeFunctionData({abi:v.parseAbi(['function transfer(address,uint256) returns(bool)']),functionName:'transfer',args:[r.addresses.source,SOURCE]}));
  r.testSubsidies.push({source:r.addresses.source,hollar:SOURCE.toString(),reason:'source entry-cost gap and initial ramp headroom'});save();
 }
 console.log('source negativeCarryBps',await readSig(r.addresses.source,'function negativeCarryBps() view returns(uint256)'));
 for(const vault of r.vaults)console.log(vault.name,'ready',await readSig(vault.mainDebt,'function ready() view returns(bool)'),'vault underfunded',await read('CollateralVault',vault.address,'isUnderfunded'));
}finally{await c.api.disconnect();}
