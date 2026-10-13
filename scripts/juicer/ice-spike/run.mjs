// lark-only ICE spike: deploy probe, fund, submit one resolvable and one expiring intent
import {createRequire} from 'node:module';
import {readFileSync,writeFileSync} from 'node:fs';
const require=createRequire('/home/mrq/git/money-market-prop-carry/scripts/propeller/x.mjs');
const {ApiPromise,WsProvider}=require('@polkadot/api');const v=require('viem');const {mnemonicToAccount}=require('viem/accounts');
const RPC='https://node4.lark.hydration.cloud';
const chain={id:222222,name:'Lark 4 Hydration',nativeCurrency:{name:'WETH',symbol:'WETH',decimals:18},rpcUrls:{default:{http:[RPC]}}};
const api=await ApiPromise.create({provider:new WsProvider('wss://node4.lark.hydration.cloud'),noInitWarn:true});
const pub=v.createPublicClient({chain,transport:v.http(RPC)});
const account=mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:17});
const wallet=v.createWalletClient({chain,account,transport:v.http(RPC)});
const art=JSON.parse(readFileSync('/tmp/ice-spike/out/IntentProbe.sol/IntentProbe.json','utf8'));
const H='0x531a654d1696ED52e7275A8cede955E82620f99a',O='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760';
const AP=(await api.call.erc20MappingApi.assetAddress(1043)).toString();
const erc=v.parseAbi(['function transfer(address,uint256) returns(bool)','function balanceOf(address) view returns(uint256)']);
const send=async(args)=>{const h=await wallet.writeContract({...args,type:'legacy',gasPrice:(await pub.getGasPrice())*2n});const r=await pub.waitForTransactionReceipt({hash:h,timeout:180000});if(r.status!=='success')throw Error('reverted '+h);return r;};
const state=JSON.parse((()=>{try{return readFileSync('/tmp/ice-spike/state.json','utf8')}catch{return '{}'}})());
if(!state.probe){
 const h=await wallet.deployContract({abi:art.abi,bytecode:art.bytecode.object,args:[H,AP],type:'legacy',gasPrice:(await pub.getGasPrice())*2n});
 const r=await pub.waitForTransactionReceipt({hash:h,timeout:180000});state.probe=r.contractAddress;writeFileSync('/tmp/ice-spike/state.json',JSON.stringify(state));
 console.log('deployed',state.probe,'gas',r.gasUsed);
}
const probe=state.probe,abi=art.abi;
if(!state.funded){await send({address:H,abi:erc,functionName:'transfer',args:[probe,12n*10n**18n]});state.funded=true;writeFileSync('/tmp/ice-spike/state.json',JSON.stringify(state));console.log('funded 20 HOLLAR');}
const price=a=>pub.readContract({address:O,abi:v.parseAbi(['function getAssetPrice(address) view returns(uint256)']),functionName:'getAssetPrice',args:[a]});
const [pH,pP]=await Promise.all([price(H),price('0x000000000000000000000000000000010000002b')]);
const amountIn=10n*10n**18n,fair=amountIn*pH/pP/10n**12n,min=fair*(10000n-6n)/10000n;
const now=(await api.query.timestamp.now()).toNumber();
const scale=(minOut,deadline,tag)=>api.tx.intent.submitIntent({data:{Swap:{assetIn:222,assetOut:1043,amountIn:amountIn.toString(),amountOut:minOut.toString(),partial:false}},deadline,onResolved:{Forward:{contract:probe,data:tag}}}).method.toHex();
for(const [key,minOut,deadline,tag] of [['resolvable',min,now+1800000,'0xc0ffee01']]){
 if(state[key])continue;
 const r=await send({address:probe,abi,functionName:'submit',args:[scale(minOut,deadline,tag)]});
 const at=await api.at(await api.rpc.chain.getBlockHash(Number(r.blockNumber)));
 const ev=(await at.query.system.events()).filter(({event})=>event.section==='intent').map(({event})=>({m:event.method,d:event.data.toJSON()}));
 state[key]={tx:r.transactionHash,block:Number(r.blockNumber),gas:r.gasUsed.toString(),minOut:minOut.toString(),fair:fair.toString(),deadline,events:ev};
 writeFileSync('/tmp/ice-spike/state.json',JSON.stringify(state));
 console.log(key,'block',r.blockNumber,'gas',r.gasUsed,'events',JSON.stringify(ev).slice(0,300));
}
const bal=async a=>(await pub.readContract({address:a,abi:erc,functionName:'balanceOf',args:[probe]}));
console.log('probe HOLLAR',Number(await bal(H))/1e18,'aPRIME',Number(await bal(AP))/1e6,'fair aPRIME',Number(fair)/1e6,'min',Number(min)/1e6);
await api.disconnect();
