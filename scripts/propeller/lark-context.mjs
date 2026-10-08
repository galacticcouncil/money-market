// Testnet deployment support. Deliberately cannot target a mainnet endpoint.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {artifact, artifactManifest, maxTransactionGas} from './native-artifacts.mjs';
import {GENESIS, COMMIT, FILE} from './lark-pins.mjs';
const require = createRequire(import.meta.url);
const {ApiPromise, WsProvider, Keyring} = require('@polkadot/api');
const {cryptoWaitReady} = require('@polkadot/util-crypto');
const v = require('viem');
const {mnemonicToAccount} = require('viem/accounts');
const RPC = 'https://4.lark.hydration.cloud';
const WS = 'wss://node4.lark.hydration.cloud';
export const GOV = '0xAa7e0000000000000000000000000000000Aa7e0';
export const POOL = '0x1b02E051683b5cfaC5929C25E84adb26ECf87B38';
export const HOLLAR = '0x531a654d1696ED52e7275A8cede955E82620f99a';
export const token = id => `0x${(0x100000000n + BigInt(id)).toString(16).padStart(40, '0')}`;
// Public Hardhat development mnemonic, separate indexes from existing services.
// These accounts must never hold real assets or be used outside Lark testnet.
export const testAccount = index => mnemonicToAccount('test test test test test test test test test test test junk', {addressIndex:index});
export const deployer = testAccount(17), keeper = testAccount(18);
export const live = process.argv.includes('--live');
const json = value => JSON.stringify(value, (_,x)=>typeof x==='bigint'?x.toString():x,2);
export const role = name => name ? v.keccak256(v.toHex(name)) : v.zeroHash;
export {artifact, v};
export async function context() {
  await cryptoWaitReady();
  const api = await ApiPromise.create({provider:new WsProvider(WS, 2500, {}, 60000),noInitWarn:true});
  const chainName = (await api.rpc.system.chain()).toString();
  assert.equal(chainName,'Lark 4 Hydration');
  const genesis = (await api.rpc.chain.getBlockHash(0)).toHex();
  assert.equal(genesis,GENESIS,'This deployment is pinned to one Lark genesis; see lark-pins.mjs');
  const chain = {id:222222,name:'Lark 4 Hydration',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:[RPC]}}};
  const directRpc='https://node4.lark.hydration.cloud';
  const pub = v.createPublicClient({chain,transport:v.http(directRpc,{timeout:60000,retryCount:3}),pollingInterval:2000,cacheTime:0});
  assert.equal(await pub.getChainId(),222222);
  // the eth rpc imports the substrate best block a moment later
  const head = BigInt((await api.rpc.chain.getHeader()).number.toString());
  let b;
  for(let i=0;!b;i++){try{b=await pub.getBlock({blockNumber:head});}catch(e){if(i>=10||!/could not be found/.test(e.message))throw e;await new Promise(resolve=>setTimeout(resolve,1500));}}
  assert.ok(Math.abs(Date.now()/1000-Number(b.timestamp))<120,'Lark head is stale');
  assert.deepEqual(Array.from(api.tx.router.sell.callIndex),[67,0]);
  const wallet = v.createWalletClient({account:deployer,chain,transport:v.http(directRpc,{timeout:60000})});
  const r = existsSync(FILE)?JSON.parse(readFileSync(FILE,'utf8')):{rpc:RPC,genesis,commit:COMMIT,startedAt:new Date().toISOString(),testnetOnly:true,deployments:[],calls:[],governance:[],addresses:{},checks:{},testSigners:{deployer:deployer.address,keeper:keeper.address}};
  assert.equal(r.rpc,RPC);assert.equal(r.genesis,genesis,'Lark was reset; do not reuse this deployment record');
  r.runtime=(await api.rpc.state.getRuntimeVersion()).specVersion.toNumber();
  const save=()=>{r.artifacts={...r.artifacts,...artifactManifest};writeFileSync(FILE,json(r)+'\n');};
  const read=(name,address,functionName,args=[])=>pub.readContract({address,abi:artifact(name).abi,functionName,args});
  const readSig=(address,signature,args=[])=>{const abi=v.parseAbi([signature]);return pub.readContract({address,abi,functionName:abi[0].name,args});};
  const alice = new Keyring({type:'sr25519'}).addFromUri('//Alice');
  const arb = new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261005-arb');
  async function sign(tx,label,signer=alice) {
    assert.ok(live,'--live required');
    let rec=r.calls.find(x=>x.label===label&&!x.evm&&!x.rejected);
    if(rec?.blockHash){assert.notEqual(rec.success,false,`${label}: previous dispatch failed`);return rec;}
    if(!rec){
      let nonce=(await api.rpc.system.accountNextIndex(signer.address)).toNumber();
      const previous=r.calls.filter(x=>!x.evm&&x.blockHash&&(!x.signer||x.signer===signer.address)).at(-1);
      if(previous){
        if(previous.nonce===undefined){const at=await api.at(previous.blockHash);const used=(await at.query.system.account(signer.address)).nonce.toNumber();nonce=Math.max(nonce,used);}
        else nonce=Math.max(nonce,previous.nonce+1);
      }
      // lark's load-balanced block-hash reads can disagree with the signing header
      // (BadProof on mortal extrinsics), so sign immortal against the verified genesis
      await tx.signAsync(signer,{nonce,era:0,blockHash:genesis,genesisHash:genesis});
      rec={label,hash:tx.hash.toHex(),nonce,signer:signer.address,signedExtrinsic:tx.toHex(),submittedAt:new Date().toISOString()};r.calls.push(rec);save();
    }else tx=api.tx(rec.signedExtrinsic);
    return new Promise((resolve,reject)=>{
      let unsub,settled=false;const timeout=setTimeout(()=>{unsub?.();reject(Error(`Timed out ${label}; reconcile known hash ${rec.hash} before retry`));},180000);
      tx.send(({status,dispatchError,events,txHash})=>{
        if(status.isInvalid||status.isDropped||status.isUsurped){settled=true;clearTimeout(timeout);unsub?.();rec.rejected=status.type;save();reject(Error(`${label}: ${status.type}`));return;}
        if (!(status.isInBlock||status.isFinalized)) return;
        settled=true;clearTimeout(timeout);unsub?.();
        Object.assign(rec,{hash:txHash.toHex(),blockHash:status.isInBlock?status.asInBlock.toHex():status.asFinalized.toHex(),success:!dispatchError,events:events.map(({event})=>({section:event.section,method:event.method,data:event.data.toJSON()}))});save();
        if (dispatchError) {const e=dispatchError.isModule?api.registry.findMetaError(dispatchError.asModule):{section:'',name:dispatchError.toString()};reject(Error(`${label}: ${e.section}.${e.name}`));return;}
        console.log('SUBSTRATE',label,rec.hash);resolve(rec);
      }).then(u=>{unsub=u;if(settled)u();}).catch(e=>{clearTimeout(timeout);reject(e);});
    });
  }
  async function enact(label,calls) {
    let rec=r.governance.find(g=>g.label===label);
    if(rec?.verified)return;
    const call=api.tx.utility.batchAll(calls), hash=call.method.hash.toHex(),len=call.method.encodedLength;
    if(rec)assert.equal(rec.hash,hash,'governance payload changed during resume');
    else{rec={label,hash,len,hex:call.method.toHex()};r.governance.push(rec);save();}
    console.log('GOVERNANCE',label,hash,'calls',calls.length);
    if(rec.ref===undefined){
      const dry=await api.call.dryRunApi.dryRunCall({system:'Root'},call,4);
      assert.ok(dry.isOk,`${label}: runtime rejected dry run: ${dry}`);
      assert.ok(dry.asOk.executionResult.isOk,`${label}: dry-run dispatch failed: ${dry.asOk.executionResult}`);
      assert.ok(!dry.asOk.emittedEvents.some(e=>/ExecutedFailed|ExtrinsicFailed|BatchInterrupted/.test(e.method)),`${label}: dry-run inner EVM failure`);
      rec.dryRunPassed=true;save();
    }
    if(!live)return;
    if(rec.ref===undefined){
      try{await sign(api.tx.preimage.notePreimage(rec.hex),`${label}.preimage`);}catch(e){if(!/AlreadyNoted/.test(String(e)))throw e;}
      const result=await sign(api.tx.referenda.submit({system:'Root'},{Lookup:{hash,len}},{After:1}),`${label}.submit`);
      const event=result.events.find(e=>e.section==='referenda'&&e.method==='Submitted');assert.ok(event);
      rec.ref=Number(event.data[0]);rec.submittedBlock=(await api.rpc.chain.getHeader(result.blockHash)).number.toNumber();save();
    }
    let info=(await api.query.referenda.referendumInfoFor(rec.ref)).unwrap();
    if(info.isOngoing&&!rec.voted){
      // clear only this deployment's completed votes; other teams' votes, ongoing
      // referenda and conviction locks stay untouched
      const voting=await api.query.convictionVoting.votingFor(alice.address,0);
      if(voting.isCasting){
        const votes=new Set(voting.asCasting.votes.map(([index])=>index.toNumber()));
        const removals=[];
        for(const previous of r.governance.filter(g=>g.ref!==undefined&&g.ref!==rec.ref&&votes.has(g.ref))){
          const old=await api.query.referenda.referendumInfoFor(previous.ref);
          if(old.isSome&&!old.unwrap().isOngoing)removals.push(api.tx.convictionVoting.removeVote(0,previous.ref));
        }
        if(removals.length)await sign(api.tx.utility.batchAll(removals),`${label}.clear-completed-deployment-votes`);
      }
      if(info.asOngoing.decisionDeposit.isNone)await sign(api.tx.referenda.placeDecisionDeposit(rec.ref),`${label}.decision-deposit`);
      await sign(api.tx.convictionVoting.vote(rec.ref,{Standard:{vote:{aye:true,conviction:'Locked6x'},balance:(4000000000n*10n**12n).toString()}}),`${label}.vote`);
      rec.voted=true;save();
    }
    const until=Date.now()+240000;
    while(Date.now()<until){
      info=(await api.query.referenda.referendumInfoFor(rec.ref)).unwrap();
      if(info.isApproved)break;
      assert.ok(info.isOngoing,`referendum ${rec.ref}: ${info.type}`);
      await new Promise(resolve=>setTimeout(resolve,3000));
    }
    assert.ok(info.isApproved,`referendum ${rec.ref} not approved yet`);
    const approved=info.asApproved[0].toNumber();
    const approvedState=await api.at(await api.rpc.chain.getBlockHash(approved));
    let expectedTask;
    for(let n=approved+1;n<=approved+12;n++){
      const agenda=await approvedState.query.scheduler.agenda(n);
      for(let i=0;i<agenda.length;i++)if(agenda[i].isSome){
        const task=agenda[i].unwrap().toJSON();
        if(JSON.stringify(task.call).toLowerCase().includes(hash.toLowerCase()))expectedTask={block:n,index:i};
      }
    }
    assert.ok(expectedTask,`${label}: no scheduled task matches the exact preimage`);
    const n=expectedTask.block;
    while((await api.rpc.chain.getHeader()).number.toNumber()<n){assert.ok(Date.now()<until,'enactment timeout');await new Promise(resolve=>setTimeout(resolve,3000));}
    const at=await api.at(await api.rpc.chain.getBlockHash(n));
    const events=(await at.query.system.events()).map(({event})=>({section:event.section,method:event.method,data:event.data.toJSON()}));
    const failure=events.find(e=>e.section==='scheduler'&&/CallUnavailable|PermanentlyOverweight/.test(e.method)&&Number(e.data[0][0])===expectedTask.block&&Number(e.data[0][1])===expectedTask.index);
    if(failure){rec.failure={block:n,event:failure};save();throw Error(`${label}: ${failure.method}; do not resubmit without fixing the payload`);}
    const dispatch=events.find(e=>e.section==='scheduler'&&e.method==='Dispatched'&&Number(e.data[0][0])===expectedTask.block&&Number(e.data[0][1])===expectedTask.index);
    if(dispatch){
      const relevant=events.filter(e=>['evm','scheduler','dispatcher','assetRegistry','utility','currencies','evmAccounts','duster'].includes(e.section));
      rec.enactment={block:n,events:relevant};save();
      assert.ok(!relevant.some(e=>/Failed|Unavailable|Overweight|Interrupted/.test(e.method)),`${label}: inner call failed`);
      assert.ok(!JSON.stringify(dispatch.data).includes('"err"'),`${label}: scheduler failed`);
      rec.verified=true;save();console.log('ENACTED',label,'referendum',rec.ref,'block',n);return;
    }
    throw Error(`No matching scheduler event for referendum ${rec.ref}`);
  }
  async function evmSend(label,to,data,creation=false) {
    let rec=r.calls.find(c=>c.label===label&&c.evm&&!c.rejected);
    if(rec?.receipt){assert.equal(rec.receipt.status,'success');return rec.receipt;}
    assert.ok(live,'--live required for EVM deployment');
    if(!rec){
      const gasPrice=await pub.getGasPrice()*2n;
      const margin=creation?110n:120n,ceiling=maxTransactionGas*100n/margin;
      const args={from:deployer.address,...(to?{to}:{}),data,gas:v.toHex(ceiling),gasPrice:v.toHex(gasPrice)};
      const estimate=BigInt(await pub.request({method:'eth_estimateGas',params:[args,'latest']}));
      const gas=(estimate*margin+99n)/100n;assert.ok(gas<=maxTransactionGas,`${label}: gas exceeds budget`);
      await pub.call({account:deployer.address,to,data,gas,gasPrice});
      // Subway may briefly cache the pending nonce after a mined receipt.
      const nonce=Math.max(await pub.getTransactionCount({address:deployer.address,blockTag:'pending'}),...r.calls.filter(c=>c.evm&&c.receipt?.status==='success').map(c=>c.nonce+1));
      const serialized=await wallet.signTransaction({chainId:222222,account:deployer,...(to?{to}:{}),data,gas,gasPrice,nonce,type:'legacy'});
      const hash=v.keccak256(serialized);rec={label,evm:true,hash,nonce,estimate,gas,gasPrice,dataHash:v.keccak256(data),to};r.calls.push(rec);save();
      try{await pub.sendRawTransaction({serializedTransaction:serialized});}catch(e){
        if(/nonce too low/i.test(e.details??e.message)&&r.calls.some(c=>c!==rec&&c.evm&&c.nonce===rec.nonce&&c.receipt?.status==='success')){rec.rejected='cached nonce already consumed by recorded successful transaction';save();}
        throw Error(`Submission failed for ${label}; reconcile ${hash} before retry: ${e.details??e.shortMessage??e.message.split('\n')[0]}`);
      }
    }
    const receipt=await pub.waitForTransactionReceipt({hash:rec.hash,timeout:180000});
    rec.receipt={status:receipt.status,contractAddress:receipt.contractAddress,block:receipt.blockNumber,gasUsed:receipt.gasUsed};save();
    assert.equal(receipt.status,'success',`${label} reverted`);console.log('EVM',label,rec.hash,'gas',receipt.gasUsed.toString());return rec.receipt;
  }
  async function deploy(name,args=[],label=name){
    const a=artifact(name),prev=r.deployments.find(d=>d.label===label);
    if(prev){assert.equal(v.keccak256(await pub.getBytecode({address:prev.address})),prev.codeHash);return prev.address;}
    assert.ok((a.deployedBytecode.object.replace(/^0x/,'').length/2)<=24576,`${name} exceeds EIP170`);
    const data=v.encodeDeployData({abi:a.abi,bytecode:a.bytecode.object,args});assert.ok((data.length-2)/2<=49152);
    const rec=await evmSend(`deploy.${label}`,undefined,data,true),address=rec.contractAddress;
    const code=await pub.getBytecode({address});assert.ok(code&&code!=='0x');
    const expected=a.deployedBytecode.object.replace(/^0x/,'').toLowerCase();let actual=code.slice(2).toLowerCase();
    let masked=expected;
    for(const refs of Object.values(a.deployedBytecode.immutableReferences??{}))for(const {start,length}of refs){actual=actual.slice(0,start*2)+'0'.repeat(length*2)+actual.slice((start+length)*2);masked=masked.slice(0,start*2)+'0'.repeat(length*2)+masked.slice((start+length)*2);}
    assert.equal(actual,masked,`${name} runtime differs from artifact outside immutables`);
    r.deployments.push({name,label,address,codeHash:v.keccak256(code),runtimeBytes:(code.length-2)/2,block:rec.block});save();console.log('DEPLOYED',label,address);return address;
  }
  const write=(label,name,address,functionName,args=[])=>evmSend(label,address,v.encodeFunctionData({abi:artifact(name).abi,functionName,args}));
  const govEvm=(address,abi,fn,args,gas=3000000)=>api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV,address,v.encodeFunctionData({abi,functionName:fn,args}),'0',gas,'100000000',null,null,[],[]));
  const nativeAccount=async address=>(await api.call.evmAccountsApi.accountId(address)).toString();
  // a fresh mainnet fork gives //Alice no HOLLAR: mint public test inventory from
  // a governance-owned facilitator bucket instead of transferring
  const hollarAbi=v.parseAbi(['function addFacilitator(address,string,uint128)','function mint(address,uint256)','function getFacilitator(address) view returns((uint128,uint128,string))']);
  async function mintTestHollar(label,to,amount){
    const [capacity]=await pub.readContract({address:HOLLAR,abi:hollarAbi,functionName:'getFacilitator',args:[GOV]});
    const calls=capacity===0n?[govEvm(HOLLAR,hollarAbi,'addFacilitator',[GOV,'Lark test inventory',1000000n*10n**18n],500000)]:[];
    await enact(label,[...calls,govEvm(HOLLAR,hollarAbi,'mint',[to,amount],500000)]);
  }
  return {api,pub,r,save,read,readSig,sign,enact,evmSend,deploy,write,govEvm,nativeAccount,mintTestHollar,arb};
}
