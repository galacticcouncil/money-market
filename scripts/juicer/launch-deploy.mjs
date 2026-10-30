// Deployer-only Juicer launch. Deploys every contract with governance as admin from construction,
// then makes no call: the wiring is the one launch referendum (tasks/proposals/juicer.ts, which reads
// JUICER_MANIFEST). Resumes from the manifest; rerun with JUICER_LAUNCH_VAULTS=ETH to add a vault.
//   JUICER_ARTIFACT_DIR (reviewed london build), JUICER_ADAPTER_ARTIFACT (HydraAugustus),
//   JUICER_DEPLOY_ARTIFACT_DIR (deploy/ helpers), RPC (eth http), WS (default from RPC)
//   mainnet: JUICER_DEPLOYER_KEY_FILE; --fork: a public dev key, local endpoints only
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {artifact,artifactManifest,maxTransactionGas} from './native-artifacts.mjs';
import {GOV,COMMITTEE,POOL,HOLLAR,HOLLAR_DEBT,DISPATCH,token,SYNTH,LOOP,QUOTES,ROLES,roundingPolicy,launchVaults} from './launch-manifest.mjs';
const require=createRequire(import.meta.url);
const {ApiPromise,WsProvider}=require('@polkadot/api');
const v=require('viem');
const {privateKeyToAccount,mnemonicToAccount}=require('viem/accounts');
const FILE=process.argv[2],fork=process.argv.includes('--fork');
assert.ok(FILE&&!FILE.startsWith('--'),'usage: launch-deploy.mjs <manifest.json> [--fork]');
const RPC=process.env.RPC,WS=process.env.WS||RPC?.replace(/^http/,'ws');
assert.ok(RPC,'set RPC to the eth rpc');
if(fork)for(const url of [RPC,WS])assert.match(new URL(url).hostname,/^(127\.0\.0\.1|localhost)$/,'--fork deploys with a public dev key, to a local fork only');
else assert.ok(process.env.JUICER_DEPLOYER_KEY_FILE,'set JUICER_DEPLOYER_KEY_FILE (a path, never the key), or --fork');
const account=fork?mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:Number(process.env.JUICER_DEPLOYER_INDEX??21)})
 :privateKeyToAccount(readFileSync(process.env.JUICER_DEPLOYER_KEY_FILE,'utf8').trim());
const HELPERS=process.env.JUICER_DEPLOY_ARTIFACT_DIR;
assert.ok(HELPERS,'set JUICER_DEPLOY_ARTIFACT_DIR to the london build of juicer-vault/deploy');
const helper=name=>{
 const file=resolve(HELPERS,`${name}.sol`,`${name}.json`),bytes=readFileSync(file),a=JSON.parse(bytes);
 const settings=(typeof a.metadata==='string'?JSON.parse(a.metadata):a.metadata).settings;
 assert.equal(settings.evmVersion,'london',`${name}: expected a london build`);
 artifactManifest[name]={file,sha256:createHash('sha256').update(bytes).digest('hex')};
 return a;
};
const hex=x=>x.startsWith('0x')?x:`0x${x}`;
const json=x=>JSON.stringify(x,(_,y)=>typeof y==='bigint'?y.toString():y,2)+'\n';
const api=await ApiPromise.create({provider:new WsProvider(WS,2500,{},120000),noInitWarn:true});
try{
 const genesis=(await api.rpc.chain.getBlockHash(0)).toHex();
 const chain={id:222222,name:'Hydration',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:[RPC]}}};
 const pub=v.createPublicClient({chain,transport:v.http(RPC,{timeout:180000}),pollingInterval:1000,cacheTime:0});
 const wallet=v.createWalletClient({account,chain,transport:v.http(RPC,{timeout:180000})});
 assert.equal(await pub.getChainId(),222222);
 const m=existsSync(FILE)?JSON.parse(readFileSync(FILE,'utf8')):{kind:'juicer-launch',chainId:222222,genesis,rpc:RPC,deployer:account.address,
  governance:GOV,committee:COMMITTEE,startedBlock:(await api.rpc.chain.getHeader()).number.toNumber(),startNonce:await pub.getTransactionCount({address:account.address}),
  deployments:[],addresses:{},vaults:[],checks:{}};
 assert.equal(m.genesis,genesis,'the manifest belongs to another chain');
 assert.equal(m.deployer.toLowerCase(),account.address.toLowerCase(),'the manifest belongs to another deployer');
 const save=()=>{m.artifacts={...m.artifacts,...artifactManifest};writeFileSync(FILE,json(m));};
 assert.ok((await api.query.evmAccounts.contractDeployer(account.address)).isSome,
  `${account.address} is not a whitelisted contract deployer: evmAccounts.addContractDeployer is a Root/GeneralAdmin decision before this runs`);
 const readSig=(address,signature,args=[])=>{const abi=v.parseAbi([signature]);return pub.readContract({address,abi,functionName:abi[0].name,args});};
 const reserve=async asset=>pub.readContract({address:POOL,abi:v.parseAbi(['function getReserveData(address) view returns ((uint256 configuration,uint128 liquidityIndex,uint128 liquidityRate,uint128 borrowIndex,uint128 borrowRate,uint128 stableRate,uint40 updatedAt,uint16 id,address aToken,address stableDebt,address variableDebt,address strategy,uint128 accrued,uint128 unbacked,uint128 isolationDebt))']),functionName:'getReserveData',args:[asset]});
 const aPrime=(await reserve(token(43))).aToken,hollarDebt=(await reserve(HOLLAR)).variableDebt;
 assert.equal(hollarDebt.toLowerCase(),HOLLAR_DEBT.toLowerCase(),'unexpected HOLLAR debt token');
 const treasury=await readSig(aPrime,'function RESERVE_TREASURY_ADDRESS() view returns (address)');
 m.market={pool:POOL,hollar:HOLLAR,hollarDebt,prime:token(43),aPrime,treasury,dispatch:DISPATCH};save();
 const gasPrice=await pub.getGasPrice()*2n;
 // every runtime equals its artifact outside the constructor-filled immutables
 const sameCode=(a,code)=>{
  let actual=code.slice(2).toLowerCase(),expected=a.deployedBytecode.object.replace(/^0x/,'').toLowerCase();
  for(const refs of Object.values(a.deployedBytecode.immutableReferences??{}))for(const {start,length}of refs){
   const mask=s=>s.slice(0,start*2)+'0'.repeat(length*2)+s.slice((start+length)*2);actual=mask(actual);expected=mask(expected);
  }
  return actual===expected;
 };
 async function deploy(label,a,args=[]){
  const prev=m.deployments.find(d=>d.label===label);
  if(prev){assert.equal(v.keccak256(await pub.getBytecode({address:prev.address})),prev.codeHash,`${label}: code changed since recorded`);return prev.address;}
  const data=v.encodeDeployData({abi:a.abi,bytecode:hex(a.bytecode.object),args});
  assert.ok((data.length-2)/2<=49152,`${label}: initcode exceeds EIP-3860`);
  const ceiling=maxTransactionGas*100n/110n;
  const estimate=BigInt(await pub.request({method:'eth_estimateGas',params:[{from:account.address,data,gas:v.toHex(ceiling),gasPrice:v.toHex(gasPrice)},'latest']}));
  const gas=(estimate*110n+99n)/100n;assert.ok(gas<=maxTransactionGas,`${label}: creation exceeds the native transaction gas cap`);
  const nonce=await pub.getTransactionCount({address:account.address,blockTag:'pending'});
  let hash;
  for(let attempt=0;;attempt++){
   // chopsticks' decoder rejects a signature whose s starts with a zero byte; a wei more re-signs it
   const serialized=await wallet.signTransaction({chainId:222222,data,gas,gasPrice:gasPrice+BigInt(attempt),nonce,type:'legacy'});
   try{hash=await pub.sendRawTransaction({serializedTransaction:serialized});break;}
   catch(e){if(attempt>=3||!String(e?.cause?.message??e).includes('Expected input with 32 bytes'))throw e;}
  }
  const r=await pub.waitForTransactionReceipt({hash,timeout:240000});
  assert.equal(r.status,'success',`${label} reverted`);
  const code=await pub.getBytecode({address:r.contractAddress});
  assert.ok(code&&code!=='0x'&&(code.length-2)/2<=24576,`${label}: no code or over EIP-170`);
  const rec={label,name:a.contractName??label.split('.')[0],address:r.contractAddress,transactionHash:hash,block:Number(r.blockNumber),nonce,gasUsed:r.gasUsed,gasLimit:gas,
   codeHash:v.keccak256(code),runtimeBytes:(code.length-2)/2,matchesArtifact:sameCode(a,code)};
  assert.ok(rec.matchesArtifact,`${label}: runtime differs from its artifact outside immutables`);
  m.deployments.push(rec);save();console.log('DEPLOYED',label,rec.address,'gas',r.gasUsed.toString());
  return rec.address;
 }
 const A=m.addresses,art=name=>({...artifact(name),contractName:name});
 // HydraAugustus owns itself to its creator; the helper creates it and hands it to governance in one transaction
 const adapterInit=v.encodeDeployData({abi:artifact('HydraAugustus').abi,bytecode:hex(artifact('HydraAugustus').bytecode.object),args:[DISPATCH]});
 A.adapterDeployment??=await deploy('OwnedDeployment.HydraAugustus',{...helper('OwnedDeployment'),contractName:'OwnedDeployment'},[adapterInit,GOV]);save();
 A.adapter??=await readSig(A.adapterDeployment,'function deployed() view returns (address)');save();
 assert.ok(sameCode(artifact('HydraAugustus'),await pub.getBytecode({address:A.adapter})),'adapter runtime differs from its artifact');
 A.compoundLogic??=await deploy('CompoundLogic',art('CompoundLogic'));save();
 A.vaultImpl??=await deploy('CollateralVault',art('CollateralVault'),[A.compoundLogic]);save();
 A.synth??=await deploy('SyntheticToken',art('SyntheticToken'),[...SYNTH,GOV]);save();
 // two transactions: one would carry both bytecodes, past a hydration transaction's limit
 A.subLogic??=await deploy('SubLoopLogic',art('SubLoopLogic'));save();
 A.subImpl??=await deploy('SubLoop',art('SubLoop'),[A.subLogic]);save();
 const loopInit=v.encodeFunctionData({abi:artifact('SubLoop').abi,functionName:'initialize',args:[POOL,HOLLAR,token(43),aPrime,...LOOP,GOV]});
 A.subLoop??=await deploy('SubLoop.proxy',art('ERC1967Proxy'),[A.subImpl,loopInit]);save();
 A.harvester??=await deploy('Harvester',art('Harvester'),[A.subLoop,token(43),GOV]);save();
 A.fees??=await deploy('JuicerFeeController',art('JuicerFeeController'),[GOV,treasury]);save();
 A.controller??=await deploy('ExecutionController',art('ExecutionController'),[GOV,...QUOTES]);save();
 const discountCode=hex(artifact('JuicerDiscount').bytecode.object);
 A.discountDeployment??=await deploy('DiscountDeployment',{...helper('DiscountDeployment'),contractName:'DiscountDeployment'},[GOV,POOL,HOLLAR_DEBT,A.synth,COMMITTEE,v.keccak256(discountCode)]);save();
 // governance's create() is its first creation, so the discount's address is fixed now
 A.discount=v.getContractAddress({from:A.discountDeployment,nonce:1n});save();
 for(const p of launchVaults(process.env.JUICER_LAUNCH_VAULTS)){
  let row=m.vaults.find(x=>x.key===p.key);
  const asset=token(p.assetId),aToken=(await reserve(asset)).aToken;
  assert.notEqual(aToken,v.zeroAddress,`${p.symbol}: collateral ${p.assetId} is not a money-market reserve`);
  const cap=BigInt(process.env[`JUICER_TVL_CAP_${p.key}`]??p.cap);
  if(!row){row={key:p.key,name:p.name,symbol:p.symbol,assetId:p.assetId,asset,aToken,cap:cap.toString()};m.vaults.push(row);save();}
  const init=v.encodeFunctionData({abi:artifact('CollateralVault').abi,functionName:'initialize',
   args:[row.name,row.symbol,asset,POOL,A.subLoop,A.adapter,HOLLAR,A.synth,aToken,HOLLAR_DEBT,BigInt(row.cap),GOV]});
  row.address??=await deploy(`CollateralVault.${p.key}.proxy`,art('ERC1967Proxy'),[A.vaultImpl,init]);save();
  row.mainDebt??=await deploy(`MainDebt.${p.key}`,art('JuicerMainDebt'),[row.address]);save();
  row.yieldAccounting??=await readSig(row.mainDebt,'function yieldAccounting() view returns (address)');
  row.rounding??=roundingPolicy(row.address,p.assetId,(await api.query.assetRegistry.assets(p.assetId)).unwrap().existentialDeposit.toString());save();
 }
 // nothing granted to the deployer, everything to governance, no proxy admin, implementations sealed
 const id=name=>name==='DEFAULT_ADMIN_ROLE'?v.zeroHash:v.keccak256(v.toHex(name));
 const roleAbi=v.parseAbi(['function hasRole(bytes32,address) view returns (bool)']);
 const has=(address,role,who)=>pub.readContract({address,abi:roleAbi,functionName:'hasRole',args:[id(role),who]});
 const vaults=m.vaults.filter(x=>x.address);
 const controlled=[A.synth,A.subLoop,A.harvester,A.fees,A.controller,...vaults.map(x=>x.address)];
 const held=[];
 for(const address of [...controlled,A.subImpl,A.vaultImpl])for(const role of ROLES)if(await has(address,role,account.address))held.push(`${address}:${role}`);
 assert.deepEqual(held,[],`the deployer holds roles: ${held.join(', ')}`);
 const admin=[[A.synth,'DEFAULT_ADMIN_ROLE'],[A.subLoop,'ADMIN_ROLE'],[A.subLoop,'UPGRADER_ROLE'],[A.harvester,'DEFAULT_ADMIN_ROLE'],[A.fees,'DEFAULT_ADMIN_ROLE'],[A.controller,'DEFAULT_ADMIN_ROLE'],
  ...vaults.flatMap(x=>[[x.address,'ADMIN_ROLE'],[x.address,'UPGRADER_ROLE'],[x.address,'GUARDIAN_ROLE']])];
 for(const [address,role]of admin)assert.ok(await has(address,role,GOV),`governance lacks ${role} on ${address}`);
 assert.equal((await readSig(A.adapter,'function owner() view returns (address)')).toLowerCase(),GOV.toLowerCase(),'adapter not owned by governance');
 assert.equal((await readSig(A.discountDeployment,'function governance() view returns (address)')).toLowerCase(),GOV.toLowerCase());
 assert.equal(await readSig(A.discountDeployment,'function discount() view returns (address)'),v.zeroAddress,'the discount exists already');
 const slot=async(address,s)=>BigInt((await api.query.evm.accountStorages(address,s)).toHex());
 const IMPL='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',ADMIN='0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
 for(const [proxy,impl]of [[A.subLoop,A.subImpl],...vaults.map(x=>[x.address,A.vaultImpl])]){
  assert.equal(await slot(proxy,IMPL),BigInt(impl),`${proxy}: implementation slot`);assert.equal(await slot(proxy,ADMIN),0n,`${proxy}: proxy admin set`);
 }
 for(const [name,impl,args]of [['SubLoop',A.subImpl,[POOL,HOLLAR,token(43),aPrime,...LOOP,account.address]],
  ['CollateralVault',A.vaultImpl,['x','x',token(1000765),POOL,A.subLoop,A.adapter,HOLLAR,A.synth,aPrime,HOLLAR_DEBT,1n,account.address]]]){
  const data=v.encodeFunctionData({abi:artifact(name).abi,functionName:'initialize',args});
  await assert.rejects(pub.call({account:account.address,to:impl,data}),`the ${name} implementation can be initialized`);
 }
 for(const x of vaults){
  assert.equal((await readSig(x.address,'function mainDebt() view returns (address)')),v.zeroAddress,`${x.symbol}: Main ledger bound outside the referendum`);
  assert.equal((await readSig(x.mainDebt,'function vault() view returns (address)')).toLowerCase(),x.address.toLowerCase());
 }
 // every transaction the deployer sent created a contract
 assert.equal(await pub.getTransactionCount({address:account.address}),m.startNonce+m.deployments.length,'the deployer sent something besides its deployments');
 m.checks={deployerHoldsNoRole:true,governanceAdmin:true,adapterOwnedByGovernance:true,proxiesHaveNoAdmin:true,implementationsSealed:true,runtimesMatchArtifacts:m.deployments.every(d=>d.matchesArtifact),
  onlyCreations:`${m.deployments.length} transactions, nonces ${m.startNonce}..${m.startNonce+m.deployments.length-1}, all contract creations`};
 m.finishedBlock=(await api.rpc.chain.getHeader()).number.toNumber();save();
 console.log('LAUNCH DEPLOYED',FILE,JSON.stringify(A));
}finally{await api.disconnect();}
