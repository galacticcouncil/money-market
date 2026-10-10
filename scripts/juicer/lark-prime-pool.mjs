// Lark only: pool 143 (PRIME/HOLLAR) carries every loop entry, unwind and peg trade. A pool
// shallower than --min-depth-usd gets liquidity up to --target-depth-usd at its current
// ratio, so the price never moves: minted to the deployer's account (PRIME within its
// deposit fuse, HOLLAR from the test facilitator) and added as it, in one referendum.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {context,deployer,HOLLAR,token,live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const require=createRequire(import.meta.url),{blake2AsU8a}=require('@polkadot/util-crypto'),{u8aConcat,stringToU8a,u8aToHex,bnToU8a}=require('@polkadot/util');
const arg=(name,fallback)=>process.argv.find(a=>a.startsWith(`--${name}=`))?.split('=')[1]??fallback;
const MIN=BigInt(arg('min-depth-usd',profile.primePool.minDepthUsd)),TARGET=BigInt(arg('target-depth-usd',profile.primePool.targetDepthUsd));
assert.ok(TARGET>=MIN,'target depth below the minimum');
const ID=143,ORACLE='0xAD33C0F0C42C5A0EAA65b5895D2BdB20cb6E8760',LABEL='prime-pool-liquidity';
const account=u8aToHex(blake2AsU8a(u8aConcat(stringToU8a('sts'),bnToU8a(ID,{bitLength:32,isLe:true})),256));
const plain=x=>JSON.parse(JSON.stringify(x,(_,y)=>typeof y==='bigint'?y.toString():y));
const c=await context();
try{
 const {api,r,save,readSig,enact}=c;
 const held=async id=>(await api.call.currenciesApi.account(id,account)).free.toBigInt();
 const price=address=>readSig(ORACLE,'function getAssetPrice(address) view returns(uint256)',[address]);
 const depth=async()=>{
  const [prime,hollar,primeUsd8,hollarUsd8]=await Promise.all([held(43),held(222),price(token(43)),price(HOLLAR)]);
  return {prime,hollar,usd:(prime*primeUsd8/10n**6n+hollar*hollarUsd8/10n**18n)/10n**8n};
 };
 const before=await depth(),rec=r.governance.find(g=>g.label===LABEL);
 console.log('POOL 143',JSON.stringify(plain(before)));
 // a recorded top-up resumes with its recorded amounts, never recomputed ones
 if(!rec?.verified&&(rec||before.usd<MIN)){
  if(!rec){
   assert.ok(before.prime>0n&&before.hollar>0n,'pool 143 is empty; seed it by hand at the oracle price');
   const scale=x=>x*(TARGET-before.usd)/before.usd;
   r.primePool={before:plain(before),add:{prime:scale(before.prime).toString(),hollar:scale(before.hollar).toString(),lp:deployer.address},note:'test liquidity; not yield'};save();
  }
  const prime=BigInt(r.primePool.add.prime),hollar=BigInt(r.primePool.add.hollar);
  const fuse=await c.fuseHeadroom(43);
  assert.ok(fuse===null||prime<=fuse,`PRIME ${prime} exceeds the deposit fuse headroom ${fuse}`);
  const lp=await c.nativeAccount(deployer.address),mint=await c.hollarMint(deployer.address,hollar);
  assert.ok(hollar<=mint.headroom,`HOLLAR ${hollar} exceeds the facilitator headroom ${mint.headroom}`);
  const calls=[api.tx.currencies.updateBalance(lp,43,prime.toString()),...mint.calls,
   api.tx.utility.dispatchAs({system:{Signed:lp}},api.tx.stableswap.addAssetsLiquidity(ID,[{assetId:43,amount:prime.toString()},{assetId:222,amount:hollar.toString()}],0))];
  // dispatchAs reports an inner failure as an event, not a failed batch
  const dry=await api.call.dryRunApi.dryRunCall({system:'Root'},api.tx.utility.batchAll(calls),4);
  assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`${LABEL}: dry run failed`);
  const added=dry.asOk.emittedEvents.find(e=>e.section==='utility'&&e.method==='DispatchedAs');
  assert.ok(added?.data[0].isOk,`${LABEL}: adding liquidity fails: ${added?.data[0]}`);
  await enact(LABEL,calls);
 }
 if(live){
  const after=await depth();
  assert.ok(after.usd>=MIN,`pool 143 holds $${after.usd}, under $${MIN}`);
  r.primePool={...r.primePool,after:plain(after),minDepthUsd:MIN.toString()};r.checks.primePool=true;save();
  console.log('POOL 143 READY',JSON.stringify(plain(after)));
 }
}finally{await c.api.disconnect();}
