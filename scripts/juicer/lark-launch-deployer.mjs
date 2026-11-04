// Lark only, before the launch deploy: what mainnet's deployer already has, a contract-deployer whitelist entry and
// gas, for the test deployer, and nothing else, so the launch referendum plans against untouched mainnet state.
import assert from 'node:assert/strict';
import {context,deployer,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
assert.ok(profile.launch,`${profile.name} is not a launch-process profile`);
const LABEL='launch-deployer-whitelist-and-gas',GAS=[[0,1000n*10n**12n],[20,10n**18n]];
const c=await context();
try{
 const {api,pub,r,save,enact,nativeAccount}=c;
 const who=await nativeAccount(deployer.address);
 const whitelisted=async()=>(await api.query.evmAccounts.contractDeployer(deployer.address)).isSome;
 r.launchDeployer??={address:deployer.address,who,gas:GAS.map(([id,amount])=>({id,amount:amount.toString()}))};save();
 await enact(LABEL,[...(await whitelisted()?[]:[api.tx.evmAccounts.addContractDeployer(deployer.address)]),
  ...GAS.map(([id,amount])=>api.tx.currencies.updateBalance(who,id,amount.toString()))]);
 if(live){
  assert.ok(await whitelisted(),`${deployer.address} is not a whitelisted contract deployer`);
  const weth=await pub.getBalance({address:deployer.address});
  assert.ok(weth>0n,`${deployer.address} has no gas`);
  r.checks.launchDeployer=true;save();
  console.log('LAUNCH DEPLOYER',deployer.address,'whitelisted, WETH',weth.toString());
 }
}finally{await c.api.disconnect();}
