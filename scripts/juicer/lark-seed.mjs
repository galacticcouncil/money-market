// Lark only: the seed mechanism behind lark-seed-bots and lark-refill-bots. Token-type assets
// are minted within each deposit fuse, aTokens supplied from minted underlying as the bot
// itself (dispatchAs), so nothing races a live bot's nonce, and HOLLAR comes from the test
// facilitator to the bot's bound EVM address. One referendum per round; every amount lands
// in the journal.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {live} from './lark-context.mjs';
import {profile} from './lark-pins.mjs';
const {Keyring}=createRequire(import.meta.url)('@polkadot/api');
export const HOLLAR_ID=222;
export const units=(n,d)=>BigInt(Math.round(n*1e6))*10n**BigInt(d)/1000000n;
const pair=bot=>{assert.ok(profile.signers[bot],`no signer for bot ${bot}`);return new Keyring({type:'sr25519'}).addFromUri(profile.signers[bot]);};
export const botAddress=bot=>pair(bot).address;
export const botEvm=bot=>'0x'+Buffer.from(pair(bot).publicKey.slice(0,20)).toString('hex');
// [bot, asset, units to mint, aToken to supply it into (optional)] -> fuse raises, mints, supplies
export async function seedCalls(c,{plan,raises=[]}){
 const {api}=c,decimals={},minted={};
 for(const [,id,n] of plan){
  decimals[id]??=Number((await api.query.assetRegistry.assets(id)).unwrap().decimals.toString());
  minted[id]=(minted[id]??0n)+units(n,decimals[id]);
 }
 const calls=raises.map(([id,n])=>api.tx.assetRegistry.update(id,null,null,null,units(n,decimals[id]).toString(),null,null,null,null)),wraps=[];
 let facilitator;
 for(const [bot,id,n,aToken] of plan){
  const amount=units(n,decimals[id]);
  if(id===HOLLAR_ID){const mint=await c.hollarMint(botEvm(bot),amount);calls.push(...(facilitator?mint.calls.slice(-1):mint.calls));facilitator??=mint;}
  else calls.push(api.tx.currencies.updateBalance(botAddress(bot),id,amount.toString()));
  if(aToken)wraps.push(api.tx.utility.dispatchAs({system:{Signed:botAddress(bot)}},
   api.tx.router.sell(id,aToken,amount.toString(),(amount*99n/100n).toString(),[{pool:'Aave',assetIn:id,assetOut:aToken}])));
 }
 calls.push(...wraps);
 return {calls,wraps:wraps.length,decimals,minted,hollarHeadroom:facilitator?.headroom};
}
export async function recordSeed(c,{round,plan,raises=[],entry={}}){
 const {api,r,save}=c,label=`bots-seed-${round}`;
 r.testSeeds??=[];
 if(!r.testSeeds.some(s=>s.round===round))r.testSeeds.push({round,...entry,...(raises.length?{fuseRaises:raises.map(([asset,units])=>({asset,units}))}:{}),plan:plan.map(([bot,asset,units,aToken])=>({bot,asset,units,...(aToken?{suppliedAs:aToken}:{})})),ref:r.governance.find(g=>g.label===label)?.ref,note:'test inventory; spent only by market simulation'});
 save();
 for(const [bot,id] of plan)if(id!==HOLLAR_ID)assert.equal((await api.query.tokens.accounts(botAddress(bot),id)).reserved.toBigInt(),0n,`${id} parked by the fuse`);
 for(const [bot,id,,aToken] of plan){
  const held=(await api.call.currenciesApi.account(aToken??id,botAddress(bot))).free.toString();
  console.log('HELD',bot,aToken??id,held);
 }
}
// checks, dry run, then one referendum; dryRunOnly leaves no journal record outside --live
export async function seedRound(c,{round,plan,raises=[],dryRunOnly=false,entry}){
 const {api,r,enact}=c,label=`bots-seed-${round}`;
 const {calls,wraps,decimals,minted,hollarHeadroom}=await seedCalls(c,{plan,raises});
 if(!r.governance.find(g=>g.label===label)?.verified)for(const [id,amount] of Object.entries(minted)){
  if(Number(id)===HOLLAR_ID){assert.ok(amount<=hollarHeadroom,`HOLLAR: ${amount} exceeds the facilitator headroom (${hollarHeadroom} left)`);continue;}
  const raised=raises.find(([x])=>x===Number(id));
  const room=await c.fuseHeadroom(Number(id),raised?units(raised[1],decimals[id]):undefined);
  if(room!==null)assert.ok(amount<=room,`${id}: ${amount} would trip the deposit fuse (${room} left)`);
 }
 // dispatchAs reports an inner failure as an event, not a failed batch
 const dry=await api.call.dryRunApi.dryRunCall({system:'Root'},api.tx.utility.batchAll(calls),4);
 assert.ok(dry.isOk&&dry.asOk.executionResult.isOk,`${label}: dry run failed`);
 const dispatched=dry.asOk.emittedEvents.filter(e=>e.section==='utility'&&e.method==='DispatchedAs');
 assert.equal(dispatched.length,wraps);
 for(const e of dispatched)assert.ok(e.data[0].isOk,`${label}: a supply fails: ${e.data[0]}`);
 if(dryRunOnly&&!live)return {label,calls};
 await enact(label,calls);
 if(live)await recordSeed(c,{round,plan,raises,entry});
 return {label,calls};
}
