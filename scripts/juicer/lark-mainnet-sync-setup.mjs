// Lark only: let the public bot signers keep oracles, omnipool prices and trade
// flow in step with mainnet. Feeds are discovered from live market and peg config.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,v,testAccount,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
const ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760',POOL='0x1b02E051683b5cfaC5929C25E84adb26ECf87B38';
const c=await context();
try{
 const {api,pub,r,save,readSig,govEvm,enact}=c;
 const mirror=testAccount(19).address;
 const sources=new Set();
 for(const asset of await readSig(POOL,'function getReservesList() view returns(address[])'))sources.add((await readSig(ORACLE,'function getSourceOfAsset(address) view returns(address)',[asset])).toLowerCase());
 for(const [,peg]of await api.query.stableswap.poolPegs.entries())for(const s of peg.toJSON().source??[])if(s.mmOracle)sources.add(s.mmOracle.toLowerCase());
 const dia=new Map(),pushers=[];
 for(const address of sources){
  if(((await pub.getBytecode({address}))??'0x').length<=2)continue;
  const oracleAddress=await readSig(address,'function diaOracleAddress() view returns(address)').catch(()=>null);
  if(oracleAddress){const key=await readSig(address,'function pairKey() view returns(string)');(dia.get(oracleAddress.toLowerCase())??dia.set(oracleAddress.toLowerCase(),[]).get(oracleAddress.toLowerCase())).push(key);continue;}
  if(await readSig(address,'function pusher() view returns(address)').catch(()=>null))pushers.push({address,name:await readSig(address,'function description() view returns(string)')});
 }
 const anchor=222,omnipool=(await api.query.omnipool.assets.entries()).map(([k])=>k.args[0].toNumber());
 const kr=new Keyring({type:'sr25519'}),pools=kr.addFromUri(profile.signers.pools),replay=kr.addFromUri(profile.signers.replay);
 const evmOf=pair=>'0x'+Buffer.from(pair.publicKey.slice(0,20)).toString('hex');
 r.mainnetSync={feeds:{dia:[...dia].map(([address,keys])=>({address,keys})),pushers},omnipool:{anchor,assets:omnipool},signers:{mirror,pools:pools.address,replay:replay.address}};save();
 // DIA keeps its updater in slot 1; the pusher feeds are governance-owned
 const word=x=>'0x'+x.slice(2).toLowerCase().padStart(64,'0');
 await enact('mirror-mainnet-oracles',[
  api.tx.system.setStorage([...dia.keys()].map(address=>[api.query.evm.accountStorages.key(address,word('0x1')),word(mirror)])),
  ...pushers.map(p=>govEvm(p.address,v.parseAbi(['function setPusher(address)']),'setPusher',[mirror],500000)),
 ]);
 // test inventory: pool sync 5% of each Token-type omnipool reserve, replay 1% of issuance
 const OMNI='0x6d6f646c6f6d6e69706f6f6c0000000000000000000000000000000000000000';
 const stable=new Set((await api.query.stableswap.pools.entries()).flatMap(([,p])=>p.unwrap().assets.map(a=>a.toNumber())));
 const funding=[];
 for(const id of new Set([0,...omnipool,...stable])){
  const meta=await api.query.assetRegistry.assets(id);if(meta.isSome&&meta.unwrap().assetType.toString()!=='Token')continue;
  const issuance=BigInt((id===0?await api.query.balances.totalIssuance():await api.query.tokens.totalIssuance(id)).toString());
  if(issuance===0n)continue;
  funding.push([replay,id,issuance/100n]);
  if(omnipool.includes(id))funding.push([pools,id,BigInt((await api.call.currenciesApi.account(id,OMNI)).free.toString())/20n]);
 }
 r.mainnetSync.funding=funding.map(([who,id,amount])=>({who:who.address,id,amount:amount.toString()}));save();
 await enact('fund-mainnet-sync-signers',[...[pools,replay].map(p=>api.tx.duster.whitelistAccount(p.address)),
  ...funding.map(([who,id,amount])=>api.tx.currencies.updateBalance(who.address,id,amount.toString()))]);
 for(const [name,pair]of [['pools',pools],['replay',replay]]){
  if((await api.query.evmAccounts.accountExtension(evmOf(pair))).isNone)await c.sign(api.tx.evmAccounts.bindEvmAddress(),`${name}.bind-evm`,pair);
  await c.mintTestHollar(`${name}.mint-test-hollar`,evmOf(pair),200000n*10n**18n);
 }
 if(live){
  for(const address of dia.keys())assert.equal((await pub.getStorageAt({address,slot:word('0x1')})).toLowerCase(),word(mirror));
  for(const p of pushers)assert.equal((await readSig(p.address,'function pusher() view returns(address)')).toLowerCase(),mirror.toLowerCase());
  r.checks.mainnetSync=true;save();
  console.log('SYNC READY',JSON.stringify({dia:[...dia].map(([a,k])=>`${a.slice(0,8)}:${k.length}`),pushers:pushers.map(p=>p.name),omnipool:omnipool.length,funded:funding.length}));
 }
}finally{await c.api.disconnect();}
