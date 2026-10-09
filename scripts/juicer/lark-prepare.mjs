// Allocate isolated public TEST accounts, never modify old vaults or reset Lark.
import assert from 'node:assert/strict';
import {context,deployer,keeper,live} from './lark-context.mjs';
const c=await context();
try{
  const {api,r,save,arb,nativeAccount}=c;
  const targets=[
    {name:'deployer',who:await nativeAccount(deployer.address),address:deployer.address,balances:[[0,1000n*10n**12n],[20,10n**18n],[34,20n*10n**18n],[1000765,10n**18n]]},
    {name:'keeper',who:await nativeAccount(keeper.address),address:keeper.address,balances:[[0,100n*10n**12n],[20,10n**18n]]},
    {name:'arb',who:arb.address,balances:[[0,1000n*10n**12n],[43,100000n*10n**6n],[34,100n*10n**18n],[1000765,5n*10n**18n]]},
  ];
  r.testFunding=targets;save();
  const calls=[];
  if(!(await api.query.evmAccounts.contractDeployer(deployer.address)).isSome)calls.push(api.tx.evmAccounts.addContractDeployer(deployer.address));
  for(const target of targets){
    calls.push(api.tx.duster.whitelistAccount(target.who));
    for(const [id,amount]of target.balances)calls.push(api.tx.currencies.updateBalance(target.who,id,amount.toString()));
  }
  await c.enact('fund-isolated-test-accounts',calls);
  if(live){
    assert.ok((await api.query.evmAccounts.contractDeployer(deployer.address)).isSome);
    assert.ok(await c.pub.getBalance({address:deployer.address})>0n);
    assert.ok(await c.pub.getBalance({address:keeper.address})>0n);
    r.checks.testAccountsFunded=true;save();
  }
  console.log('TEST ACCOUNTS',deployer.address,keeper.address,arb.address);
}finally{await c.api.disconnect();}
