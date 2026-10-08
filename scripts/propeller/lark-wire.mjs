import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,artifact,v,POOL,HOLLAR,token,deployer,role,live} from './lark-context.mjs';
const require=createRequire(import.meta.url), poolAbi=require('../../deployments/hydration/Pool-Implementation.json').abi;
const c=await context();
try{
 const {r,api,pub,readSig,govEvm,enact,save}=c,a=r.addresses;
 assert.equal(r.sourceSlippagePpm,undefined,'Initial wiring is complete; do not overwrite later approved execution policy');
 assert.equal(r.vaults?.length,2);
 const provider=await readSig(POOL,'function ADDRESSES_PROVIDER() view returns(address)');
 const configurator=await readSig(provider,'function getPoolConfigurator() view returns(address)');
 const oracle=await readSig(provider,'function getPriceOracle() view returns(address)');
 const reserve=await pub.readContract({address:POOL,abi:poolAbi,functionName:'getReserveData',args:[token(34)]});
 const slot='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
 const implementation=async address=>`0x${(await api.query.evm.accountStorages(address,slot)).toHex().slice(-40)}`;
 const input={aTokenImpl:await implementation(reserve.aTokenAddress),stableDebtTokenImpl:await implementation(reserve.stableDebtTokenAddress),variableDebtTokenImpl:await implementation(reserve.variableDebtTokenAddress),underlyingAssetDecimals:18,interestRateStrategyAddress:reserve.interestRateStrategyAddress,underlyingAsset:a.synth,treasury:r.feeRecipient,incentivesController:await readSig(reserve.aTokenAddress,'function getIncentivesController() view returns(address)'),aTokenName:'Propeller October Synthetic aToken',aTokenSymbol:'aPS-OCT',variableDebtTokenName:'Propeller October Variable Debt',variableDebtTokenSymbol:'vdPS-OCT',stableDebtTokenName:'Propeller October Stable Debt',stableDebtTokenSymbol:'sdPS-OCT',params:'0x'};
 const cfg=v.parseAbi(['function initReserves((address aTokenImpl,address stableDebtTokenImpl,address variableDebtTokenImpl,uint8 underlyingAssetDecimals,address interestRateStrategyAddress,address underlyingAsset,address treasury,address incentivesController,string aTokenName,string aTokenSymbol,string variableDebtTokenName,string variableDebtTokenSymbol,string stableDebtTokenName,string stableDebtTokenSymbol,bytes params)[])','function configureReserveAsCollateral(address,uint256,uint256,uint256)','function setReserveBorrowing(address,bool)','function setSupplyCap(address,uint256)']);
 r.synthAssetId=5551;save();
 const loc={parents:0,interior:{X1:[{AccountKey20:{network:null,key:a.synth}}]}};
 const nativeName='Propeller October HOLLAR';
 assert.ok(Buffer.byteLength(nativeName)<=api.consts.assetRegistry.stringLimit.toNumber());
 await enact('list-october-synthetic-v2',[
   api.tx.assetRegistry.register(5551,nativeName,'Erc20','10000000000000000','psHOL-OCT',18,loc,null,true),
   govEvm(configurator,cfg,'initReserves',[[input]],10000000),
 ]);
 if(live){
  const sr=await pub.readContract({address:POOL,abi:poolAbi,functionName:'getReserveData',args:[a.synth]});assert.notEqual(sr.aTokenAddress,v.zeroAddress);a.aSynthetic=sr.aTokenAddress;save();
  const contract=(name,address,fn,args,gas=500000)=>govEvm(address,artifact(name).abi,fn,args,gas);
  const configure=[govEvm(configurator,cfg,'configureReserveAsCollateral',[a.synth,100n,9800n,10100n],500000),govEvm(configurator,cfg,'setReserveBorrowing',[a.synth,false],500000),govEvm(oracle,v.parseAbi(['function setAssetSources(address[],address[])']),'setAssetSources',[[a.synth],['0x6096C9D71F7c06024578a62F4B608a1Bb06834F8']],500000),contract('SubLoop',a.source,'configureDca',[222,43,1043,143,0]),contract('SubLoop',a.source,'setTranches',[50n*10n**18n,50n*10n**6n]),contract('SubLoop',a.source,'setHarvester',[a.harvester]),contract('Harvester',a.harvester,'setFeeController',[a.fees])];
  await enact('configure-october-source',configure);
  for(const vault of r.vaults){
   const calls=[contract('SyntheticToken',a.synth,'grantRole',[role('MINTER_ROLE'),vault.address]),contract('SubLoop',a.source,'registerVault',[vault.address]),contract('CollateralVault',vault.address,'setMainDebt',[vault.mainDebt]),contract('CollateralVault',vault.address,'setFeeController',[a.fees]),contract('PropellerFeeController',a.fees,'registerVault',[vault.address,a.harvester]),contract('Harvester',a.harvester,'addVault',[vault.address]),contract('CollateralVault',vault.address,'setCompoundSlippageBps',[0]),contract('CollateralVault',vault.address,'setWithdrawalDelay',[60]),contract('CollateralVault',vault.address,'grantRole',[role('ADMIN_ROLE'),deployer.address]),contract('CollateralVault',vault.address,'pauseDeposits',[])];
   await enact(`wire-${vault.name}-vault`,calls);
  }
  const custody=[a.source,a.harvester,a.fees,...r.vaults.flatMap(x=>[x.address,x.mainDebt,x.yieldAccounting])];
  await enact('protect-october-custody',await Promise.all(custody.map(async address=>api.tx.duster.whitelistAccount(await c.nativeAccount(address)))));
  const expiry=r.executionPolicy?.expiresAt??Number((await pub.getBlock()).timestamp+30n*86400n);
  const definitions=[['entry',HOLLAR,1000n*10n**18n,10n**18n,60],['unwind',r.market.aPrime,1000n*10n**6n,10n**6n,60],['harvest',token(43),1000n*10n**6n,10n**6n,60],['service-ETH',token(34),10n**18n,10n**15n,60],['service-TBTC',token(1000765),10n**17n,10n**14n,60]];
  r.executionPolicy={maxQuoteAge:60,maxQuoteBlocks:5,expiresAt:expiry,budgets:[],limits:[]};
  for(const [name,asset,capacity,refill,interval]of definitions){
   const group=v.keccak256(v.toHex(`lark-october-${name}`));
   r.executionPolicy.budgets.push({name,group,token:asset,capacity:capacity.toString(),refillPerSecond:refill.toString(),expiresAt:expiry,minIntervalSeconds:interval});
  }
  const policy=r.executionPolicy;
  const lanes=[[a.source,HOLLAR,r.market.aPrime,'entry',10n**18n,50n*10n**18n,false],[a.source,r.market.aPrime,HOLLAR,'unwind',10000n,50n*10n**6n,true]];
  for(const vault of r.vaults){
   lanes.push([vault.address,token(43),vault.asset,'harvest',10000n,50n*10n**6n,false]);
   for(const consumer of [vault.address,vault.mainDebt])lanes.push([consumer,vault.asset,HOLLAR,`service-${vault.name}`,vault.assetId===34?10n**12n:10n**10n,vault.assetId===34?2n*10n**16n:10n**15n,false]);
  }
  for(const [consumer,input,output,groupName,minimum,maximum,safety]of lanes){
   const group=policy.budgets.find(x=>x.name===groupName).group,lane=v.keccak256(v.encodeAbiParameters(v.parseAbiParameters('address,address,address'),[consumer,input,output]));
   policy.limits.push({consumer,input,output,lane,group,minimum:minimum.toString(),maximum:maximum.toString(),maxShortfallBps:0,safety});
  }
  save();
  const budgetCalls=policy.budgets.flatMap(b=>[contract('ExecutionController',a.controller,'configureBudget',[b.group,b.token,BigInt(b.capacity),BigInt(b.refillPerSecond),BigInt(b.expiresAt)]),contract('ExecutionController',a.controller,'configurePacing',[b.group,BigInt(b.minIntervalSeconds)])]);
  await enact('execution-budgets',budgetCalls);
  for(let i=0;i<policy.limits.length;i+=4){
   const calls=policy.limits.slice(i,i+4).flatMap(l=>[contract('ExecutionController',a.controller,'configureLimit',[l.consumer,l.input,l.output,l.group,BigInt(l.minimum),BigInt(l.maximum)]),contract('ExecutionController',a.controller,'configurePrice',[l.lane,0,l.safety])]);
   await enact(`execution-lanes-${i}`,calls);
  }
  const actions=[[a.source,'pokeBorrow()'],[a.source,'pokeRepay()'],[a.harvester,'harvest(uint256[])'],...r.vaults.map(x=>[x.address,'rebalance()'])];
  await enact('bind-execution-controller',[
   ...actions.map(([target,signature])=>contract('ExecutionController',a.controller,'configureAction',[target,v.toFunctionSelector(signature),true])),
   ...[['SubLoop',a.source],['Harvester',a.harvester],...r.vaults.map(x=>['CollateralVault',x.address])].map(([name,address])=>contract(name,address,'setExecutionController',[a.controller])),
  ]);
  r.status='wired-deposits-paused-awaiting-price-and-bootstrap';save();
 }
}finally{await c.api.disconnect();}
