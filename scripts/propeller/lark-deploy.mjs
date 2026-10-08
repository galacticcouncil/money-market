import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,artifact,v,GOV,POOL,HOLLAR,token,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const DISPATCH='0x0000000000000000000000000000000000000401';
const require=createRequire(import.meta.url);
const poolAbi=require('../../deployments/hydration/Pool-Implementation.json').abi;
const c=await context();
try{
  assert.ok(live,'--live required; lark-prepare.mjs prepares accounts separately');
  const {r,pub,deploy,read,readSig,write,save}=c;
  assert.ok(r.checks.testAccountsFunded);
  const reserves={};
  for(const [name,address]of [['ETH',token(34)],['TBTC',token(1000765)],['PRIME',token(43)],['HOLLAR',HOLLAR]]){
    reserves[name]=await pub.readContract({address:POOL,abi:poolAbi,functionName:'getReserveData',args:[address]});
    assert.notEqual(reserves[name].aTokenAddress,v.zeroAddress);
    console.log('RESERVE',name,'LTV',(reserves[name].configuration.data&65535n).toString());
  }
  // a fresh mainnet fork has no HydraAugustus; deploy the pinned adapter and hand it to governance
  const swapper=await deploy('HydraAugustus',[DISPATCH]);
  for(const [address,id]of [[token(43),43],[HOLLAR,222],[token(34),34],[token(1000765),1000765]]){
    if(Number(await read('HydraAugustus',swapper,'assetId',[address]))!==id)await write(`swapper.asset${id}`,'HydraAugustus',swapper,'setAssetId',[address,id]);
  }
  if((await read('HydraAugustus',swapper,'owner')).toLowerCase()!==GOV.toLowerCase())await write('swapper.owner','HydraAugustus',swapper,'transferOwnership',[GOV]);
  const swapperCode=await pub.getBytecode({address:swapper});
  r.market={pool:POOL,hollar:HOLLAR,prime:token(43),aPrime:reserves.PRIME.aTokenAddress,hollarDebt:reserves.HOLLAR.variableDebtTokenAddress,swapper,swapperCodeHash:v.keccak256(swapperCode),deployedAdapter:true};save();
  const a=r.addresses;
  a.vaultImpl=await deploy('CollateralVault');save();
  a.compoundLogic=await read('CollateralVault',a.vaultImpl,'compoundLogic');save();
  assert.equal((await pub.getBytecode({address:a.compoundLogic})).toLowerCase(),artifact('CompoundLogic').deployedBytecode.object.toLowerCase());
  a.synth=await deploy('SyntheticToken',[...profile.names.synth,GOV]);save();
  a.subImpl=await deploy('SubLoop');save();
  const sourceInit=v.encodeFunctionData({abi:artifact('SubLoop').abi,functionName:'initialize',args:[POOL,HOLLAR,token(43),reserves.PRIME.aTokenAddress,1050000000000000000n,1100000000000000000n,GOV]});
  a.source=await deploy('ERC1967Proxy',[a.subImpl,sourceInit],'SubLoop.proxy');save();
  a.harvester=await deploy('Harvester',[a.source,token(43),GOV]);save();
  const treasury=await readSig(reserves.ETH.aTokenAddress,'function RESERVE_TREASURY_ADDRESS() view returns(address)');
  a.fees=await deploy('PropellerFeeController',[GOV,treasury]);save();
  a.controller=await deploy('ExecutionController',[GOV,60n,5n]);save();
  r.feeRecipient=treasury;
  r.vaults??=[];
  for(const [name,id,cap]of [['ETH',34,10n*10n**18n],['TBTC',1000765,10n**18n/2n]]){
    let row=r.vaults.find(x=>x.name===name);
    if(!row){row={name,assetId:id,asset:token(id),aToken:reserves[name].aTokenAddress,cap};r.vaults.push(row);save();}
    const init=v.encodeFunctionData({abi:artifact('CollateralVault').abi,functionName:'initialize',args:[...profile.names.vaults[name],row.asset,POOL,a.source,swapper,HOLLAR,a.synth,row.aToken,reserves.HOLLAR.variableDebtTokenAddress,BigInt(row.cap),GOV]});
    row.address=await deploy('ERC1967Proxy',[a.vaultImpl,init],`CollateralVault.${name}.proxy`);save();
    row.mainDebt=await deploy('PropellerMainDebt',[row.address],`MainDebt.${name}`);save();
    row.yieldAccounting=await read('PropellerMainDebt',row.mainDebt,'yieldAccounting');save();
    assert.equal(await read('CollateralVault',row.address,'deferredDeployment'),true);
    const raw=(await c.api.query.assetRegistry.assets(id)).unwrap();
    const ed=BigInt(raw.existentialDeposit.toString());row.rounding={vault:row.address,assetId:id,minimum:(ed*2n+1000n).toString(),target:(ed*10n+1000000000n).toString()};save();
  }
  r.status='fresh-core-deployed-awaiting-governance';save();
  console.log('CORE DEPLOYED',JSON.stringify(a));
}finally{await c.api.disconnect();}
