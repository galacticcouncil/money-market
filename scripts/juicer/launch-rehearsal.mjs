// The launch, end to end on a local chopsticks fork of mainnet. Test fixtures (storage writes, public dev
// keys) are confined here and to local endpoints; the deploy and the proposal run unchanged.
//   prepare             whitelist and fund the dev deployer, keeper and user; instant blocks for the deploy
//   enact <hex file>    note, submit, pass and enact the ONE Root referendum, then every scheduled batch
//   smoke <manifest>    a tBTC deposit, a keeper rebalance and intent, a headroom exit and exact claims
// WS (default ws://127.0.0.1:18098), JUICER_REHEARSAL_REPORT (default /tmp/juicer-launch-rehearsal.json)
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {existsSync,readFileSync,writeFileSync} from 'node:fs';
const require=createRequire(import.meta.url);
const {ApiPromise,WsProvider,Keyring}=require('@polkadot/api');
const {blake2AsHex,cryptoWaitReady}=require('@polkadot/util-crypto');
const {compactToU8a,hexToU8a,u8aToHex,u8aConcat}=require('@polkadot/util');
const v=require('viem');
const {mnemonicToAccount}=require('viem/accounts');
const [cmd,arg]=process.argv.slice(2);
const WS=process.env.WS||'ws://127.0.0.1:18098',RPC=WS.replace(/^ws/,'http');
assert.match(new URL(WS).hostname,/^(127\.0\.0\.1|localhost)$/,'the rehearsal writes storage: local forks only');
const REPORT=process.env.JUICER_REHEARSAL_REPORT||'/tmp/juicer-launch-rehearsal.json';
const report=existsSync(REPORT)?JSON.parse(readFileSync(REPORT,'utf8')):{};
const save=()=>writeFileSync(REPORT,JSON.stringify(report,(_,x)=>typeof x==='bigint'?x.toString():x,2)+'\n');
const dev=i=>mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:i});
const deployer=dev(Number(process.env.JUICER_DEPLOYER_INDEX??21)),keeper=dev(22),user=dev(23);
const TBTC=1000765,WETH=20,GOV='0xAa7e0000000000000000000000000000000Aa7e0';
const provider=new WsProvider(WS,2500,{},600000);
const api=await ApiPromise.create({provider,noInitWarn:true});
const send=(method,params)=>provider.send(method,params);
const head=async()=>(await api.rpc.chain.getHeader()).number.toNumber();
const account=async address=>(await api.call.evmAccountsApi.accountId(address)).toString();
const chain={id:222222,name:'Hydration fork',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:[RPC]}}};
const pub=v.createPublicClient({chain,transport:v.http(RPC,{timeout:180000}),pollingInterval:500,cacheTime:0});
async function fund(address,balances,native){
 const who=native??await account(address),items=[];
 for(const [id,amount]of balances){
  if(id===0)items.push([api.query.system.account.key(who),api.registry.createType('AccountInfo',{nonce:(await api.query.system.account(who)).nonce,providers:1,sufficients:1,data:{free:amount.toString(),reserved:0,frozen:0,flags:0}}).toHex()]);
  else items.push([api.query.tokens.accounts.key(who,id),api.registry.createType('OrmlTokensAccountData',{free:amount.toString(),reserved:0,frozen:0}).toHex()]);
 }
 await send('dev_setStorage',[items]);
 return who;
}

// events that mean a call inside the referendum did not do its job
const failed=e=>{
 const k=`${e.section}.${e.method}`;
 if(/^(evm\.ExecutedFailed|utility\.BatchInterrupted|utility\.ItemFailed|system\.ExtrinsicFailed|scheduler\.(CallUnavailable|PermanentlyOverweight|RetryFailed))$/.test(k))return true;
 const data=JSON.stringify(e.data.toJSON());
 if(/^(scheduler\.Dispatched|dispatcher\.TreasuryManagerCallDispatched|utility\.DispatchedAs|dispatcher\.AaveManagerCallDispatched)$/.test(k))return /"err"/i.test(data);
 return /DispatchError/.test(data);
};
const eventsAt=async n=>(await (await api.at(await api.rpc.chain.getBlockHash(n))).query.system.events()).map(({event})=>event);
const newBlocks=async(count=1)=>{await send('dev_newBlock',[{count}]);return head();};
// a Root call through the scheduler, as the referenda alarm would make it
async function rootCall(call,label){
 const hex=call.method.toHex(),hash=blake2AsHex(hex),len=(hex.length-2)/2,body=hexToU8a(hex);
 await send('dev_setStorage',[[[api.query.preimage.preimageFor.key([hash,len]),u8aToHex(u8aConcat(compactToU8a(body.length),body))]]]);
 await send('dev_setStorage',[{Preimage:{RequestStatusFor:[[[hash],{Requested:{maybeTicket:null,count:1,maybeLen:len}}]]}}]);
 const t=(await head())+1;
 await send('dev_setStorage',[{Scheduler:{Agenda:[[[t],[{maybeId:null,priority:0,call:{Lookup:{hash_:hash,len}},maybePeriodic:null,origin:{system:'Root'}}]]]}}]);
 await newBlocks();
 const bad=(await eventsAt(t)).filter(failed);
 assert.equal(bad.length,0,`${label}: ${bad.map(e=>`${e.section}.${e.method} ${JSON.stringify(e.data.toJSON())}`).join('; ')}`);
 return t;
}
async function signed(signer,tx,label){
 await tx.signAsync(signer,{nonce:-1});
 const hash=(await api.rpc.author.submitExtrinsic(tx)).toHex(),n=await newBlocks();
 const events=(await (await api.at(await api.rpc.chain.getBlockHash(n))).query.system.events());
 const mine=events.filter(({phase})=>phase.isApplyExtrinsic).map(({event})=>event);
 const fail=mine.find(e=>e.section==='system'&&e.method==='ExtrinsicFailed');
 assert.ok(!fail,`${label}: ${fail&&JSON.stringify(fail.data.toHuman())}`);
 console.log('SIGNED',label,'block',n,hash);
 return {block:n,events:mine};
}
async function enact(file){
 await cryptoWaitReady();
 await send('dev_setBlockBuildMode',['Manual']);
 const hex=readFileSync(file,'utf8').trim(),call=api.createType('Call',hex),hash=call.hash.toHex(),len=call.encodedLength;
 const alice=new Keyring({type:'sr25519',ss58Format:63}).addFromUri('//Alice');
 await fund(null,[[0,10_000_000n*10n**12n]],alice.address);
 const r=report.referendum={preimage:{hash,len},startBlock:await head()};save();
 // the referendum, as a proposer submits it
 await signed(alice,api.tx.preimage.notePreimage(hex),'preimage.notePreimage');
 const sub=await signed(alice,api.tx.referenda.submit({system:'Root'},{Lookup:{hash,len}},{After:1}),'referenda.submit');
 r.index=sub.events.find(e=>e.section==='referenda'&&e.method==='Submitted').data[0].toNumber();
 await signed(alice,api.tx.referenda.placeDecisionDeposit(r.index),'referenda.placeDecisionDeposit');
 await signed(alice,api.tx.convictionVoting.vote(r.index,{Standard:{vote:{aye:true,conviction:'Locked1x'},balance:(1_000_000n*10n**12n).toString()}}),'convictionVoting.vote');
 const track=api.consts.referenda.tracks.find(([id])=>id.toNumber()===0)[1];
 // time compressed: decision and confirmation periods already elapsed with a passing tally
 const info=(await api.query.referenda.referendumInfoFor(r.index)).unwrap(),og=info.asOngoing,h=await head(),big=(5_000_000_000n*10n**12n).toString();
 assert.equal(og.track.toNumber(),0,'not on the root track');
 const ongoing=api.registry.createType(og.toRawType(),{...og.toJSON(),track:0,origin:og.origin,proposal:og.proposal,enactment:og.enactment,
  deciding:{since:h-1,confirming:h-track.confirmPeriod.toNumber()-2},tally:{ayes:big,nays:0,support:big},inQueue:false,alarm:null});
 await send('dev_setStorage',[[[api.query.referenda.referendumInfoFor.key(r.index),api.registry.createType(info.toRawType(),{Ongoing:ongoing}).toHex()]]]);
 r.compressed={decidingSince:h-1,confirmingSince:h-track.confirmPeriod.toNumber()-2,note:'storage: decision and confirm periods elapsed, tally passing'};
 r.nudgeBlock=await rootCall(api.tx.referenda.nudgeReferendum(r.index),'referenda.nudgeReferendum');
 const state=(await api.query.referenda.referendumInfoFor(r.index)).unwrap();
 assert.ok(state.isApproved,`referendum ${r.index}: ${state.type}`);
 r.approvedBlock=state.asApproved[0].toNumber();save();
 // the chain's own enactment, at the track's minimum enactment period; every block mined, none skipped
 let enactAt;
 for(const [k,agenda]of await api.query.scheduler.agenda.entries())for(const t of agenda)
  if(t.isSome&&t.unwrap().call.isLookup&&t.unwrap().call.asLookup.hash_.toHex()===hash)enactAt=k.args[0].toNumber();
 assert.ok(enactAt,'enactment not scheduled');
 r.enactmentBlock=enactAt;save();
 console.log('APPROVED',r.index,'at',r.approvedBlock,'enactment at',enactAt);
 while(await head()<enactAt-1)await newBlocks(Math.min(50,enactAt-1-await head()));
 const scheduled=JSON.parse(readFileSync(process.env.JUICER_PLAN_OUT,'utf8')).batches.length;
 r.blocks=[];
 const maxW=api.consts.scheduler.maximumWeight;
 for(let n=enactAt;n<=enactAt+scheduled-1;n++){
  await newBlocks();
  const events=await eventsAt(n),at=await api.at(await api.rpc.chain.getBlockHash(n));
  const w=(await at.query.system.blockWeight()).toJSON(),mandatory=w.mandatory;
  const count=k=>events.filter(e=>`${e.section}.${e.method}`===k).length;
  const row={block:n,batch:n-enactAt,events:events.length,evmExecuted:count('evm.Executed'),executedFailed:count('evm.ExecutedFailed'),
   dispatched:events.filter(e=>e.section==='scheduler'&&e.method==='Dispatched').map(e=>e.data.toJSON()),
   treasury:count('dispatcher.TreasuryManagerCallDispatched'),failures:events.filter(failed).map(e=>`${e.section}.${e.method} ${JSON.stringify(e.data.toJSON())}`),
   mandatoryWeight:mandatory,schedulerShare:`${(Number(BigInt(mandatory.refTime))/Number(maxW.refTime.toBigInt())*100).toFixed(1)}% ref, ${(Number(BigInt(mandatory.proofSize))/Number(maxW.proofSize.toBigInt())*100).toFixed(1)}% proof`};
  r.blocks.push(row);save();
  console.log('BLOCK',n,'batch',row.batch,'evm',row.evmExecuted,'failed',row.executedFailed,'failures',row.failures.length,'weight',row.schedulerShare);
 }
 // every batch serviced in its own block, none postponed or left behind
 const left=[];
 for(let n=enactAt;n<=enactAt+scheduled-1;n++)if((await api.query.scheduler.agenda(n)).some(t=>t.isSome))left.push(n);
 r.unserviced=left;r.clean=r.blocks.every(b=>!b.failures.length)&&!left.length;save();
 console.log('ENACTED',r.clean?'clean':'WITH FAILURES',JSON.stringify(r.blocks.map(b=>[b.block,b.failures])));
}
// a user, the keeper and the queue on the enacted launch
async function smoke(file){
 const {artifact}=await import('./native-artifacts.mjs');
 const m=JSON.parse(readFileSync(file,'utf8')),vault=m.vaults.find(x=>x.address),A=m.addresses;
 await send('dev_setBlockBuildMode',['Instant']);
 const s=report.smoke={vault:vault.address,steps:[]};save();
 const abi=[...artifact('CollateralVault').abi,...artifact('CompoundLogic').abi.filter(x=>x.type==='event')];
 const loopAbi=[...artifact('SubLoop').abi,...artifact('SubLoopLogic').abi.filter(x=>x.type==='event')];
 const erc20=v.parseAbi(['function approve(address,uint256) returns (bool)','function balanceOf(address) view returns (uint256)']);
 const read=(address,a,functionName,args=[])=>pub.readContract({address,abi:a,functionName,args});
 const gasPrice=await pub.getGasPrice()*2n;
 // explicit gas: frontier's estimate can false-revert on precompile-heavy calls
 async function call(who,label,address,a,functionName,args=[],gas=6_000_000n){
  const wallet=v.createWalletClient({account:who,chain,transport:v.http(RPC,{timeout:180000})});
  let hash;
  for(let attempt=0;;attempt++){
   try{hash=await wallet.writeContract({address,abi:a,functionName,args,gas,gasPrice:gasPrice+BigInt(attempt),type:'legacy'});break;}
   catch(e){if(attempt>=3||!String(e).includes('Expected input with 32 bytes'))throw e;}
  }
  const r=await pub.waitForTransactionReceipt({hash,timeout:240000});
  const logs=[];
  for(const l of r.logs)for(const x of [abi,loopAbi,artifact('ExecutionController').abi]){
   try{const e=v.decodeEventLog({abi:x,data:l.data,topics:l.topics});logs.push({address:l.address,event:e.eventName,args:e.args});break;}catch{}
  }
  const row={label,from:who.address,block:Number(r.blockNumber),status:r.status,gasUsed:r.gasUsed,tx:hash,events:logs.map(e=>e.event)};
  s.steps.push(row);save();
  console.log('SMOKE',label,r.status,'block',row.block,'gas',r.gasUsed.toString(),row.events.join(','));
  assert.equal(r.status,'success',`${label} reverted`);
  return logs;
 }
 // the discount deployed up front is the reviewed build, bound to the aToken the referendum's initReserves made
 const discount=artifact('JuicerDiscount').deployedBytecode;
 let live=(await pub.getBytecode({address:A.discount})).slice(2).toLowerCase(),want=discount.object.replace(/^0x/,'').toLowerCase();
 for(const refs of Object.values(discount.immutableReferences??{}))for(const {start,length}of refs){
  const mask=x=>x.slice(0,start*2)+'0'.repeat(length*2)+x.slice((start+length)*2);live=mask(live);want=mask(want);
 }
 assert.equal(live,want,'the created discount differs from its artifact');
 const listed=(await read(m.market.pool,v.parseAbi(['function getReserveData(address) view returns ((uint256 configuration,uint128 liquidityIndex,uint128 liquidityRate,uint128 borrowIndex,uint128 borrowRate,uint128 stableRate,uint40 updatedAt,uint16 id,address aToken,address stableDebt,address variableDebt,address strategy,uint128 accrued,uint128 unbacked,uint128 isolationDebt))']),'getReserveData',[A.synth])).aToken;
 const bound=await read(A.discount,v.parseAbi(['function aSynthetic() view returns (address)']),'aSynthetic');
 s.discount={address:A.discount,matchesArtifact:true,prediction:m.prediction,listedAToken:listed,boundAToken:bound};save();
 assert.equal(listed.toLowerCase(),m.prediction.aSynthetic.toLowerCase(),'initReserves made another aToken than predicted');
 assert.equal(bound.toLowerCase(),listed.toLowerCase(),'the discount reads another aToken');
 const tbtc=vault.asset,amount=10n**16n;
 await call(user,'user approves 0.01 tBTC',tbtc,erc20,'approve',[vault.address,amount],500_000n);
 const before=await read(vault.address,abi,'balanceOf',[user.address]);
 await call(user,'user deposits 0.01 tBTC into jBTC',vault.address,abi,'deposit',[amount,user.address]);
 const shares=await read(vault.address,abi,'balanceOf',[user.address])-before;
 assert.ok(shares>0n,'no shares minted');s.shares=shares;
 await call(keeper,'keeper rebalances jBTC (Main borrow into the loop)',vault.address,abi,'rebalance',[]);
 const debt=await read(m.market.hollarDebt,erc20,'balanceOf',[vault.address]);
 assert.ok(debt>0n,'the rebalance borrowed nothing');s.mainDebt=debt;s.loopShares=await read(vault.address,abi,'loopShares');
 const keeperRole=await read(A.subLoop,loopAbi,'KEEPER_ROLE');
 assert.ok(await read(A.subLoop,loopAbi,'hasRole',[keeperRole,keeper.address]),'the keeper lacks KEEPER_ROLE');
 const intent=await call(keeper,'keeper pokeBorrowQuoted: the entry intent goes to ICE',A.subLoop,loopAbi,'pokeBorrowQuoted',[0n]);
 s.intent=intent.map(e=>e.event);
 // fork only: aura rejects a 12 h timestamp jump, so this request skips the withdrawal delay, restored after
 const delay=Number(await read(vault.address,abi,'withdrawalDelay'));
 const asGov=(data,label)=>rootCall(api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV,vault.address,data,0,500000,'600000000',null,null,[],[])),label);
 const delayData=d=>v.encodeFunctionData({abi,functionName:'setWithdrawalDelay',args:[d]});
 await asGov(delayData(0),'fork only: withdrawal delay 0');
 const exitShares=shares*3n/100n;
 const req=await call(user,'user requests 3% of the shares',vault.address,abi,'requestRedeem',[exitShares,user.address]);
 const id=req.find(e=>e.event==='RedeemRequested').args.requestId;s.requestId=id;
 const started=await call(keeper,'keeper starts the unwind',vault.address,abi,'startUnwinds',[1n]);
 const headroom=started.find(e=>e.event==='HeadroomExit');
 s.headroom=headroom?{kept:headroom.args.keptShares,unwound:headroom.args.unwoundShares,shortfall:headroom.args.shortfall}:null;
 assert.ok(headroom,'the exit did not take the headroom path');
 // settlement waits for the loop's in-flight intent. no solver runs on a fork, so once past its deadline the
 // keeper's cleanup signer returns the input (intent.cleanupIntent), the loop pays the callback in WETH and reconciles
 const submitted=intent.find(e=>e.event==='IntentSubmitted').args,loopAccount=await account(A.subLoop);
 const ids=(await api.query.intent.accountIntents.keys(loopAccount)).map(k=>k.args[1].toString());
 assert.equal(ids.length,1,'the loop should have exactly its entry intent in flight');
 while(BigInt((await api.query.timestamp.now()).toString())<=BigInt(submitted.deadline))await newBlocks(10);
 const wethBefore=(await api.call.currenciesApi.account(WETH,loopAccount)).free.toBigInt();
 await send('dev_setBlockBuildMode',['Manual']);
 await cryptoWaitReady();
 const alice=new Keyring({type:'sr25519',ss58Format:63}).addFromUri('//Alice');
 const cleanup=await signed(alice,api.tx.intent.cleanupIntent(ids[0]),'intent.cleanupIntent after the deadline');
 await newBlocks(3);
 await send('dev_setBlockBuildMode',['Instant']);
 s.intentCleanup={id:ids[0],deadline:submitted.deadline,block:cleanup.block,events:cleanup.events.map(e=>`${e.section}.${e.method}`),
  loopWethSpent:(wethBefore-(await api.call.currenciesApi.account(WETH,loopAccount)).free.toBigInt()).toString(),
  feeCurrency:(await api.query.multiTransactionPayment.accountCurrencyMap(loopAccount)).toJSON()};save();
 await call(keeper,'keeper reconciles the loop',A.subLoop,loopAbi,'reconcile',[]);
 assert.equal(Number((await read(A.subLoop,loopAbi,'pendingIntent'))[2]??1),0,'the intent is still pending');
 await call(keeper,'keeper settles the queue',vault.address,abi,'pokeSettle',[]);
 // owner, shares, collateralOwed, debtShare, synthShare, repaid, collateralSettled, sharesBurned, active
 const r=await read(vault.address,abi,'redemptions',[id]);
 s.redemption={collateralOwed:r[2],debtShare:r[3],repaid:r[5],collateralSettled:r[6]};
 const pending=r[6];
 assert.ok(pending>0n,'nothing settled');
 const half=pending/2n,b0=await read(tbtc,erc20,'balanceOf',[user.address]);
 await call(user,`user claims exactly ${half}`,vault.address,abi,'claim',[id,user.address,half]);
 const b1=await read(tbtc,erc20,'balanceOf',[user.address]);
 assert.equal(b1-b0,half,'the exact claim paid a different amount');
 await call(user,`user claims the remaining ${pending-half}`,vault.address,abi,'claim',[id,user.address,pending-half]);
 assert.equal(await read(tbtc,erc20,'balanceOf',[user.address])-b1,pending-half);
 await asGov(delayData(delay),`fork only: withdrawal delay back to ${delay}`);
 assert.equal(Number(await read(vault.address,abi,'withdrawalDelay')),delay);
 s.claimed=pending;s.delayOverride=`0 for request ${id}, restored to ${delay}`;s.passed=true;save();
 console.log('SMOKE PASSED',JSON.stringify(s,(_,x)=>typeof x==='bigint'?x.toString():x).slice(0,600));
}

try{
 assert.equal(Number(await send('eth_chainId',[])),222222);
 if(cmd==='prepare'){
  await send('dev_setBlockBuildMode',['Instant']);
  // mainnet's deployer is whitelisted by its own earlier decision; the dev key gets the same entry here
  await send('dev_setStorage',[[[api.query.evmAccounts.contractDeployer.key(deployer.address),'0x']]]);
  await fund(deployer.address,[[0,1000n*10n**12n],[WETH,10n**18n]]);
  await fund(keeper.address,[[0,1000n*10n**12n],[WETH,10n**18n]]);
  await fund(user.address,[[0,1000n*10n**12n],[WETH,10n**18n],[TBTC,5n*10n**16n]]);
  report.fork={block:await head(),hash:(await api.rpc.chain.getBlockHash()).toHex(),runtime:(await api.rpc.state.getRuntimeVersion()).specVersion.toNumber()};
  report.fixtures={deployer:deployer.address,keeper:keeper.address,user:user.address,note:'storage-funded public dev keys; deployer whitelisted as on mainnet'};save();
  console.log('PREPARED',JSON.stringify(report.fixtures),'fork',JSON.stringify(report.fork));
 }else if(cmd==='enact')await enact(arg);
 else if(cmd==='smoke')await smoke(arg);
 else throw Error(`unknown command ${cmd}`);
}finally{await api.disconnect();}
