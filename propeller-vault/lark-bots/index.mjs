// Public development accounts. Hard-pinned to Lark 4 + its deployment genesis.
// This market maker is subsidized by test assets, never an APY forecast.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {ApiPromise,WsProvider,Keyring} from '@polkadot/api';
import {cryptoWaitReady} from '@polkadot/util-crypto';
import {createPublicClient,createWalletClient,http,parseAbi,toHex,encodeFunctionData} from 'viem';
import {mnemonicToAccount} from 'viem/accounts';
import {fairOutput,profitableQuote,freshReference,orientRoute,retainsQuoteInventory,omnipoolRatio,sizeOmnipoolTrade,deviationBps,correctionGainBps,replayTrades} from './policy.mjs';
const RPC='https://4.lark.hydration.cloud',WS='wss://4.lark.hydration.cloud';
const SOURCE='https://hdx.tarn.hydration.cloud';
const mode=process.env.BOT_MODE||'markets',live=process.env.BOT_LIVE==='true';
const interval=Number(process.env.BOT_INTERVAL_MS||30000);
assert.ok(Number.isSafeInteger(interval)&&interval>=5000&&interval<=300000);
const manifest=JSON.parse(readFileSync(process.env.BOT_MANIFEST||'/app/manifest.json','utf8'));
const log=(name,row)=>console.log(JSON.stringify({time:new Date().toISOString(),mode,name,...row},(_,x)=>typeof x==='bigint'?x.toString():x));
const token=id=>`0x${(0x100000000n+BigInt(id)).toString(16).padStart(40,'0')}`;
const hollar='0x531a654d1696ED52e7275A8cede955E82620f99a',oracle='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
const addresses={34:token(34),43:token(43),1000765:token(1000765),222:hollar},decimals={34:18,43:6,1000765:18,222:18};
const abi=parseAbi(['function getAssetPrice(address) view returns(uint256)','function getSourceOfAsset(address) view returns(address)','function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)','function setPrice(int256)','function balanceOf(address) view returns(uint256)']);
const account=mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:19});
const chain={id:222222,name:'Lark 4 Hydration',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:[RPC]}}};
const pub=createPublicClient({chain,transport:http(RPC,{timeout:30000,retryCount:2}),cacheTime:0});
const source=createPublicClient({transport:http(SOURCE,{timeout:30000,retryCount:2}),cacheTime:0});
const wallet=createWalletClient({chain,account,transport:http(RPC,{timeout:30000})});
await cryptoWaitReady();
const api=await ApiPromise.create({provider:new WsProvider(WS),noInitWarn:true});
const signer=new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261005-arb');
// one public test signer per mode; each runs in its own container
const actor=mode==='pools'?new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261007-pools')
 :mode==='replay'?new Keyring({type:'sr25519'}).addFromUri('//Alice//propeller-20261007-replay'):signer;
const mainnet=['pools','replay'].includes(mode)?await ApiPromise.create({provider:new WsProvider(SOURCE.replace('https://','wss://')),noInitWarn:true}):null;
const OMNIPOOL='0x6d6f646c6f6d6e69706f6f6c0000000000000000000000000000000000000000';
const diaAbi=parseAbi(['function getValue(string) view returns(uint128,uint128)','function setMultipleValues(string[],uint256[])']);
const pusherAbi=parseAbi(['function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)','function setPrice(int256)']);
let pendingEvm,pendingSubstrate,nextEvmNonce=0,nextSubstrateNonce=0,stopping=false;
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>{stopping=true;});
async function identity(){
 assert.equal((await api.rpc.system.chain()).toString(),'Lark 4 Hydration');
 assert.equal((await api.rpc.chain.getBlockHash(0)).toHex(),manifest.genesis,'testnet reset');
 assert.equal(await pub.getChainId(),222222);
 // The EVM gateway can cache `latest` after a trade. Pin to the native head,
 // then read both storage and EVM prices at that explicit block number.
 const header=await api.rpc.chain.getHeader(),at=await api.at(header.hash);
 const block={number:BigInt(header.number.toString()),hash:header.hash.toHex(),timestamp:BigInt((await at.query.timestamp.now()).toString())/1000n};
 assert.ok(Math.abs(Date.now()/1000-Number(block.timestamp))<120,'stale testnet head');return block;
}
async function mirror(){
 const target=await identity(),block=await source.getBlock();
 if(pendingEvm){const receipt=await pub.getTransactionReceipt({hash:pendingEvm});assert.equal(receipt.status,'success');pendingEvm=undefined;}
 for(const row of manifest.oracles){
  const asset=row.asset,feed=await source.readContract({address:oracle,abi,functionName:'getSourceOfAsset',args:[asset],blockNumber:block.number});
  const round=await source.readContract({address:feed,abi,functionName:'latestRoundData',blockNumber:block.number});
  const price=await source.readContract({address:oracle,abi,functionName:'getAssetPrice',args:[asset],blockNumber:block.number});
  assert.ok(freshReference({price,updatedAt:round[3],chainTime:block.timestamp,headAge:Date.now()/1000-Number(block.timestamp)}),`stale upstream ${row.name}`);
  const local=await pub.readContract({address:row.address,abi,functionName:'latestRoundData'});
  const delta=price>local[1]?price-local[1]:local[1]-price;
  const update=local[1]<=0n||delta*10000n>=price||target.timestamp-local[3]>=300n;
  log('reference',{asset:row.name,price,upstreamFeed:feed,upstreamUpdatedAt:round[3],upstreamBlock:block.number,localPrice:local[1],update});
  if(!live||!update)continue;
  const gasPrice=await pub.getGasPrice()*2n,data=encodeFunctionData({abi,functionName:'setPrice',args:[price]});
  const estimate=BigInt(await pub.request({method:'eth_estimateGas',params:[{from:account.address,to:row.address,data,gas:toHex(1000000n),gasPrice:toHex(gasPrice)},'latest']}));
  const gas=(estimate*120n+99n)/100n;assert.ok(gas<=1200000n);
  await pub.simulateContract({address:row.address,abi,functionName:'setPrice',args:[price],account,gas,gasPrice});
  const nonce=Math.max(nextEvmNonce,await pub.getTransactionCount({address:account.address,blockTag:'pending'}));
  pendingEvm=await wallet.writeContract({address:row.address,abi,functionName:'setPrice',args:[price],gas,gasPrice,nonce,type:'legacy'});
  const receipt=await pub.waitForTransactionReceipt({hash:pendingEvm,timeout:180000});assert.equal(receipt.status,'success');log('mirror-mined',{asset:row.name,hash:pendingEvm,gasUsed:receipt.gasUsed});pendingEvm=undefined;nextEvmNonce=nonce+1;
 }
 await mirrorFeeds(block);
}
async function evmWrite(address,feedAbi,functionName,args,label){
 const gasPrice=await pub.getGasPrice()*2n,data=encodeFunctionData({abi:feedAbi,functionName,args});
 const estimate=BigInt(await pub.request({method:'eth_estimateGas',params:[{from:account.address,to:address,data,gas:toHex(3000000n),gasPrice:toHex(gasPrice)},'latest']}));
 const gas=(estimate*120n+99n)/100n;assert.ok(gas<=3000000n);
 await pub.simulateContract({address,abi:feedAbi,functionName,args,account,gas,gasPrice});
 const nonce=Math.max(nextEvmNonce,await pub.getTransactionCount({address:account.address,blockTag:'pending'}));
 pendingEvm=await wallet.writeContract({address,abi:feedAbi,functionName,args,gas,gasPrice,nonce,type:'legacy'});
 const receipt=await pub.waitForTransactionReceipt({hash:pendingEvm,timeout:180000});assert.equal(receipt.status,'success');
 log('mirror-mined',{feed:label,hash:pendingEvm,gasUsed:receipt.gasUsed});pendingEvm=undefined;nextEvmNonce=nonce+1;
}
// original forked feeds, so every reserve, adapter and stableswap peg follows mainnet unchanged
async function mirrorFeeds(block){
 for(const d of manifest.feeds?.dia??[]){
  const keys=[],values=[];
  for(const key of d.keys){
   const [price,updatedAt]=await source.readContract({address:d.address,abi:diaAbi,functionName:'getValue',args:[key],blockNumber:block.number});
   const [local,localAt]=await pub.readContract({address:d.address,abi:diaAbi,functionName:'getValue',args:[key]});
   const update=price>0n&&(price!==local||updatedAt!==localAt);
   log('dia-reference',{key,price,upstreamUpdatedAt:updatedAt,localPrice:local,update});
   if(update){keys.push(key);values.push((price<<128n)|updatedAt);}
  }
  if(live&&keys.length)await evmWrite(d.address,diaAbi,'setMultipleValues',[keys,values],keys.join(','));
 }
 for(const p of manifest.feeds?.pushers??[]){
  const upstream=await source.readContract({address:p.address,abi:pusherAbi,functionName:'latestRoundData',blockNumber:block.number});
  const local=await pub.readContract({address:p.address,abi:pusherAbi,functionName:'latestRoundData'});
  const update=upstream[1]>0n&&upstream[1]!==local[1];
  log('pusher-reference',{feed:p.name,price:upstream[1],localPrice:local[1],update});
  if(live&&update)await evmWrite(p.address,pusherAbi,'setPrice',[upstream[1]],p.name);
 }
}
async function quote(at,input,output,amount,route,minimum=0n){
 const tx=api.tx.router.sell(input,output,amount.toString(),minimum.toString(),route);
 const dry=await at.call.dryRunApi.dryRunCall({system:{Signed:actor.address}},tx,4);
 if(!dry.isOk)throw Error('dry run unavailable');
 if(!dry.asOk.executionResult.isOk){
  const failure=dry.asOk.executionResult.asErr,error=failure.error??failure;
  if(error.isModule){const meta=api.registry.findMetaError(error.asModule);throw Error(`${meta.section}.${meta.name}`);}
  throw Error(error.toString());
 }
 const event=dry.asOk.emittedEvents.find(e=>e.section==='router'&&e.method==='Executed');
 assert.ok(event,'missing router fill');return BigInt(event.data[3].toString());
}
async function submit(tx,label='arb-mined',requireFill=true){
 if(pendingSubstrate)throw Error('prior substrate receipt uncertain; operator must reconcile');
 pendingSubstrate=true;
 const nonce=Math.max(nextSubstrateNonce,(await api.rpc.system.accountNextIndex(actor.address)).toNumber());
 return new Promise((resolve,reject)=>{
  let unsub,settled=false;const timer=setTimeout(()=>{unsub?.();reject(Error('transaction receipt timeout'));},180000);
  tx.signAndSend(actor,{nonce,era:0,blockHash:manifest.genesis,genesisHash:manifest.genesis},({status,dispatchError,events,txHash})=>{
   if(status.isInvalid||status.isDropped||status.isUsurped){settled=true;clearTimeout(timer);unsub?.();reject(Error(`uncertain transaction ${txHash.toHex()}: ${status.type}`));return;}
   if(!status.isInBlock&&!status.isFinalized)return;
   settled=true;clearTimeout(timer);unsub?.();pendingSubstrate=false;nextSubstrateNonce=nonce+1;
   if(dispatchError){const meta=dispatchError.isModule?api.registry.findMetaError(dispatchError.asModule):null;reject(Error(`${txHash.toHex()}: ${meta?`${meta.section}.${meta.name}`:dispatchError.toString()}`));return;}
   const fills=events.filter(({event})=>event.section==='router'&&event.method==='Executed').map(({event})=>event.data.toJSON());
   if(requireFill&&!fills.length){reject(Error(`mined transaction has no router fill: ${txHash.toHex()}`));return;}
   const failed=events.filter(({event})=>event.section==='utility'&&event.method==='ItemFailed').length;
   log(label,{hash:txHash.toHex(),fills:fills.length>8?fills.length:fills,failed});resolve();
  }).then(u=>{unsub=u;if(settled)u();}).catch(e=>{clearTimeout(timer);reject(e);});
 });
}
async function markets(){
 const block=await identity(),at=await api.at(block.hash);
 const prices={222:100000000n};
 for(const id of [34,43,1000765]){
  const price=await pub.readContract({address:oracle,abi,functionName:'getAssetPrice',args:[addresses[id]],blockNumber:block.number});
  const feed=await pub.readContract({address:oracle,abi,functionName:'getSourceOfAsset',args:[addresses[id]],blockNumber:block.number});
  assert.equal(feed.toLowerCase(),manifest.oracles.find(o=>o.assetId===id).address.toLowerCase(),'unexpected testnet oracle');
  const round=await pub.readContract({address:feed,abi,functionName:'latestRoundData',blockNumber:block.number});
  assert.ok(freshReference({price,updatedAt:round[3],chainTime:block.timestamp,headAge:0,maxAge:900n}),`stale mirror ${id}: ${round[3]} at ${block.timestamp}`);prices[id]=price;
 }
 const evm='0x'+Buffer.from(signer.publicKey.slice(0,20)).toString('hex');
 assert.ok((await api.query.evmAccounts.accountExtension(evm)).isSome,'arb substrate/EVM binding required');
 const balances={};for(const id of [34,43,222,1000765])balances[id]=await pub.readContract({address:addresses[id],abi,functionName:'balanceOf',args:[evm],blockNumber:block.number});
 const fills=[],unavailable=[],inventoryBlocked=[];
 for(const [left,right]of [[43,222],[34,222],[222,1000765],[34,43],[43,1000765]])for(const [input,output]of [[left,right],[right,left]]){
  const stored=(await at.query.router.routes({assetIn:Math.min(input,output),assetOut:Math.max(input,output)})).toJSON();
  const route=orientRoute(stored??[],input,output);
  let quotes=0;
  for(const usd of [1n,100n,1000n,5000n]){
   const amount=usd*100000000n*10n**BigInt(decimals[input])/prices[input];
   if(amount>balances[input]||amount===0n)continue;
   try{
    const fair=fairOutput(amount,prices[input],prices[output],decimals[input],decimals[output]);
    const out=await quote(at,input,output,amount,route);quotes++;
    const row=profitableQuote({amount,out,fair});
    log('quote',{block:block.number,input,output,usd,amount,out,fair,shortfallBps:(fair-out)*10000n/fair});
    if(row){
     if(retainsQuoteInventory(balances[input],amount,prices[input],decimals[input]))fills.push({...row,input,output,route,usd,profitUsd8:(out-fair)*prices[output]/10n**BigInt(decimals[output])});
     else inventoryBlocked.push({input,output,usd,balance:balances[input]});
    }
   }catch(e){log('quote-rejected',{input,output,usd,error:e.message.slice(0,180)});}
  }
  if(!quotes){unavailable.push([input,output]);log('route-unavailable',{input,output,balance:balances[input]});}
 }
 fills.sort((a,b)=>a.profitUsd8>b.profitUsd8?-1:a.profitUsd8<b.profitUsd8?1:0);
 if(inventoryBlocked.length)log('inventory-refill-needed',{routes:inventoryBlocked});
 if(!fills.length){log('no-executable-arbitrage',{unavailable,inventoryBlocked});return unavailable.length===0;}
 const best=fills[0];log('selected',{...best,route:undefined});if(!live)return unavailable.length===0;
 const latest=await identity();assert.ok(latest.number-block.number<=5n&&latest.timestamp-block.timestamp<=60n,'quote expired; re-evaluate next cycle');
 const current=await api.at(latest.hash);
 await quote(current,best.input,best.output,best.amount,best.route,best.minOut);
 await submit(api.tx.router.sell(best.input,best.output,best.amount.toString(),best.minOut.toString(),best.route));
 return unavailable.length===0;
}
async function omnipoolSide(at,id){
 const asset=(await at.query.omnipool.assets(id)).unwrap(),free=(await at.call.currenciesApi.account(id,OMNIPOOL)).free;
 return {hub:BigInt(asset.hubReserve.toString()),res:BigInt(free.toString())};
}
// keep each omnipool asset's price in the anchor at mainnet's, beyond the fee band
async function pools(){
 const block=await identity(),at=await api.at(block.hash);
 const mainAt=await mainnet.at(await mainnet.rpc.chain.getFinalizedHead());
 const anchor=manifest.omnipool.anchor,band=BigInt(process.env.POOL_BAND_BPS||40);
 const larkAnchor=await omnipoolSide(at,anchor),mainAnchor=await omnipoolSide(mainAt,anchor);
 const minGain=BigInt(process.env.POOL_MIN_GAIN_BPS||5);
 let best;
 for(const id of manifest.omnipool.assets){
  if(id===anchor)continue;
  const lark=await omnipoolSide(at,id),target=omnipoolRatio(await omnipoolSide(mainAt,id),mainAnchor);
  const dev=deviationBps(omnipoolRatio(lark,larkAnchor),target);
  log('pool-reference',{asset:id,devBps:dev});
  if(dev<=band&&dev>=-band)continue;
  const input=dev>0n?id:anchor,output=dev>0n?anchor:id;
  const balance=BigInt((await at.call.currenciesApi.account(input,actor.address)).free.toString());
  const cap=(dev>0n?lark.res:larkAnchor.res)*3n/100n,max=balance*9n/10n<cap?balance*9n/10n:cap;
  const {sellAsset,amount}=sizeOmnipoolTrade(lark,larkAnchor,target,max);
  const gain=correctionGainBps(lark,larkAnchor,target,sellAsset,amount);
  if(gain<minGain){log('inventory-refill-needed',{asset:input,balance,gainBps:gain});continue;}
  if(!best||gain>best.gain)best={asset:id,devBps:dev,gain,input,output,amount};
 }
 if(!best){log('pools-aligned',{band});return true;}
 const route=[{pool:'Omnipool',assetIn:best.input,assetOut:best.output}];
 const out=await quote(at,best.input,best.output,best.amount,route);
 log('pool-correction',{asset:best.asset,devBps:best.devBps,input:best.input,amount:best.amount,out});
 if(live)await submit(api.tx.router.sell(best.input,best.output,best.amount.toString(),(out*9950n/10000n).toString(),route),'pool-mined');
 return true;
}
const REPLAYED=new Set(['router.Executed','omnipool.SellExecuted','omnipool.BuyExecuted','stableswap.SellExecuted','stableswap.BuyExecuted','xyk.SellExecuted','xyk.BuyExecuted']);
const scale=BigInt(Math.round(Number(process.env.REPLAY_SCALE||'1')*1e6));
let replayNext;
function tradeRow(name,d){
 const n=i=>Number(d[i].toString()),b=i=>BigInt(d[i].toString());
 if(name==='router.Executed')return {name,input:n(0),output:n(1),amount:b(2)};
 if(name.startsWith('omnipool.'))return {name,input:n(1),output:n(2),amount:b(3)};
 if(name.startsWith('stableswap.'))return {name,pool:n(1),input:n(2),output:n(3),amount:b(4)};
 if(name==='xyk.SellExecuted')return {name,input:n(1),output:n(2),amount:b(3)};
 return {name,input:n(2),output:n(1),amount:b(4)};
}
// replay finalized mainnet trades on Lark: same pair, same input size (times REPLAY_SCALE)
async function replay(){
 const block=await identity(),at=await api.at(block.hash);
 const head=(await mainnet.rpc.chain.getHeader(await mainnet.rpc.chain.getFinalizedHead())).number.toNumber();
 replayNext??=process.env.REPLAY_FROM?Number(process.env.REPLAY_FROM):head+1;
 const last=Math.min(head,replayNext+Number(process.env.REPLAY_MAX_BLOCKS||20)-1),groups=[];
 for(let n=replayNext;n<=last;n++){
  const phases=new Map();
  for(const {phase,event} of await (await mainnet.at(await mainnet.rpc.chain.getBlockHash(n))).query.system.events()){
   const name=`${event.section}.${event.method}`;if(!REPLAYED.has(name))continue;
   const key=phase.toString();(phases.get(key)??phases.set(key,[]).get(key)).push(tradeRow(name,event.data));
  }
  groups.push(...phases.values());
 }
 const from=replayNext;replayNext=last+1;
 const trades=replayTrades(groups),spend={},calls=[],skipped=[];
 // the hub token (H2O) is never minted for replay; it would distort omnipool accounting
 for(const t of trades.filter(t=>t.input!==1&&t.output!==1).slice(0,Number(process.env.REPLAY_BATCH||25))){
  const amount=t.amount*scale/1000000n;
  spend[t.input]??=BigInt((await at.call.currenciesApi.account(t.input,actor.address)).free.toString());
  if(amount===0n||amount>spend[t.input]){skipped.push(t.input);continue;}
  spend[t.input]-=amount;
  const stored=t.route??orientRoute((await at.query.router.routes({assetIn:Math.min(t.input,t.output),assetOut:Math.max(t.input,t.output)})).toJSON()??[],t.input,t.output);
  calls.push(api.tx.router.sell(t.input,t.output,amount.toString(),'0',stored));
 }
 log('replay-window',{mainnetFrom:from,mainnetTo:last,trades:trades.length,submitting:calls.length,skippedInputs:[...new Set(skipped)]});
 if(live&&calls.length)await submit(api.tx.utility.forceBatch(calls),'replay-mined',false);
 return true;
}
try{
 await identity();assert.ok(['markets','mirror','pools','replay'].includes(mode));
 do{
  try{const ok=(await ({mirror,markets,pools,replay})[mode]())!==false;writeFileSync('/tmp/propeller-bot-health.json',JSON.stringify({at:Date.now(),ok,mode}));if(!ok&&process.env.BOT_ONCE==='true')process.exitCode=1;}
  catch(e){log('error',{error:e.shortMessage??e.message});writeFileSync('/tmp/propeller-bot-health.json',JSON.stringify({at:Date.now(),ok:false,mode}));if(process.env.BOT_ONCE==='true')process.exitCode=1;}
  if(stopping||process.env.BOT_ONCE==='true')break;
  await new Promise(resolve=>setTimeout(resolve,interval));
 }while(!stopping);
}finally{await api.disconnect();await mainnet?.disconnect();}
