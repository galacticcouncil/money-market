// Allocate isolated public TEST accounts, never modify old vaults or reset Lark.
import assert from 'node:assert/strict';
import {context,deployer,keeper,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
import {recordBuy,buyCall,checkBuys,assertBought} from './lark-collateral.mjs';
const LABEL='fund-isolated-test-accounts',{ETH:eth,TBTC:btc}=profile.collateral;
const c=await context();
try{
  const {api,r,save,arb,nativeAccount}=c;
  const targets=[
    {name:'deployer',who:await nativeAccount(deployer.address),address:deployer.address,balances:[[0,1000n*10n**12n],[20,10n**18n],[34,20n*10n**18n],[btc.assetId,10n**18n]]},
    {name:'keeper',who:await nativeAccount(keeper.address),address:keeper.address,balances:[[0,100n*10n**12n],[20,10n**18n]]},
    {name:'arb',who:arb.address,balances:[[0,1000n*10n**12n],[43,100000n*10n**6n],[34,100n*10n**18n],[btc.assetId,5n*10n**18n]]},
  ];
  r.testFunding=targets;save();
  // a bought collateral is paid from that ETH: the bootstrap's seed and the arb's quotes
  const buys=eth.buy?[await recordBuy(c,eth,'deployer',10n**18n),await recordBuy(c,eth,'arb',10n*10n**18n)]:[];
  const calls=[];
  if(!(await api.query.evmAccounts.contractDeployer(deployer.address)).isSome)calls.push(api.tx.evmAccounts.addContractDeployer(deployer.address));
  for(const target of targets){
    calls.push(api.tx.duster.whitelistAccount(target.who));
    for(const [id,amount]of target.balances)calls.push(api.tx.currencies.updateBalance(target.who,id,amount.toString()));
    for(const b of buys.filter(b=>b.name===target.name)){
      assert.ok(BigInt(b.max)<=(target.balances.find(([id])=>id===b.from)?.[1]??0n),`${b.name}: the ${eth.symbol} buy spends more than it is minted`);
      calls.push(buyCall(api,target.who,eth,b.amount,b.max));
    }
  }
  if(buys.length)await checkBuys(c,LABEL,calls,buys.length,{collateral:eth,amount:buys.reduce((a,b)=>a+BigInt(b.amount),0n)});
  await c.enact(LABEL,calls);
  if(live){
    assert.ok((await api.query.evmAccounts.contractDeployer(deployer.address)).isSome);
    assert.ok(await c.pub.getBalance({address:deployer.address})>0n);
    assert.ok(await c.pub.getBalance({address:keeper.address})>0n);
    if(buys.length)assertBought(r,LABEL);
    r.checks.testAccountsFunded=true;save();
  }
  console.log('TEST ACCOUNTS',deployer.address,keeper.address,arb.address);
}finally{await c.api.disconnect();}
