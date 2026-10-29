import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {profile,NEXT_PARAMS,CORE_FILE as FILE} from './lark-pins.mjs';
import {ICE} from './lark-ice-plan.mjs';
const r=JSON.parse(readFileSync(FILE,'utf8'));
Object.assign(process.env,{WS_URL:profile.gateway.ws,RPC_URL:r.rpc,
 JUICER_SYNTH:r.addresses.synth,JUICER_SUBLOOP:r.addresses.source,JUICER_HARVESTER:r.addresses.harvester,
 JUICER_EXECUTION_CONTROLLER:r.addresses.controller,JUICER_EXECUTION_POLICY:JSON.stringify(r.executionPolicy),
 JUICER_VAULTS:r.vaults.map(v=>v.address).join(','),JUICER_SWAPPER:r.market.swapper,
 JUICER_GUARDIAN:r.committee,JUICER_LOOPER:r.testSigners.keeper,JUICER_FEE_CONTROLLER:r.addresses.fees,
 JUICER_FEE_RECIPIENT:r.feeRecipient,JUICER_DISCOUNT_CONTROLLER:r.addresses.discount,
 JUICER_DISCOUNT_COMMITTEE:r.committee,JUICER_DISCOUNT_BPS:'0',JUICER_SLIPPAGE_PPM:String(r.sourceSlippagePpm??0),
 JUICER_WITHDRAWAL_DELAY:'60',JUICER_SYNTH_ASSET_ID:String(r.synthAssetId),
 JUICER_ROUNDING_RESERVES:JSON.stringify(r.vaults.map(v=>v.rounding))});
// the next version's keepers, threshold, ICE, reserve, bands and launch economics; lark 4's contracts have none of it
if(!profile.legacy){
 const {band,revenue}=NEXT_PARAMS;
 Object.assign(process.env,{JUICER_KEEPERS:[r.testSigners.keeper,r.testSigners.keeperSecondary].join(','),
  JUICER_HARVEST_THRESHOLD:String(NEXT_PARAMS.harvestThreshold),JUICER_INTENT_TTL:String(ICE.ttl),JUICER_INTENT_DRIFT_BPS:String(ICE.driftBps),
  JUICER_RESERVE_HOLLAR:String(NEXT_PARAMS.reserve/10n**18n),JUICER_REBALANCE_BAND:[band.relever,band.target,band.delever].join(','),
  JUICER_DISCOUNT_BPS:String(revenue.mainDiscountBps),JUICER_LOOP_DISCOUNT_BPS:String(revenue.loopDiscountBps),
  JUICER_LOOP_DISCOUNT_CAP:String(profile.hollarBucket/10n**18n),JUICER_PROTOCOL_FEE_BPS:String(revenue.protocolFeeBps),
  ...(profile.primePool.feePpm===null?{}:{JUICER_PRIME_POOL_FEE_PPM:String(profile.primePool.feePpm)})});
}
const child=spawn(process.execPath,['--import','./juicer-vault/looper/node_modules/tsx/dist/loader.mjs','scripts/juicer/verify-readiness.ts'],{stdio:'inherit',env:process.env});
child.on('exit',code=>{process.exitCode=code??1;});
