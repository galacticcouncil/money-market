import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {profile,CORE_FILE as FILE} from './lark-pins.mjs';
const r=JSON.parse(readFileSync(FILE,'utf8'));
Object.assign(process.env,{WS_URL:profile.gateway.ws,RPC_URL:r.rpc,
 PROPELLER_SYNTH:r.addresses.synth,PROPELLER_SUBLOOP:r.addresses.source,PROPELLER_HARVESTER:r.addresses.harvester,
 PROPELLER_EXECUTION_CONTROLLER:r.addresses.controller,PROPELLER_EXECUTION_POLICY:JSON.stringify(r.executionPolicy),
 PROPELLER_VAULTS:r.vaults.map(v=>v.address).join(','),PROPELLER_SWAPPER:r.market.swapper,
 PROPELLER_GUARDIAN:r.committee,PROPELLER_LOOPER:r.testSigners.keeper,PROPELLER_FEE_CONTROLLER:r.addresses.fees,
 PROPELLER_FEE_RECIPIENT:r.feeRecipient,PROPELLER_DISCOUNT_CONTROLLER:r.addresses.discount,
 PROPELLER_DISCOUNT_COMMITTEE:r.committee,PROPELLER_DISCOUNT_BPS:'0',PROPELLER_SLIPPAGE_PPM:String(r.sourceSlippagePpm??0),
 PROPELLER_WITHDRAWAL_DELAY:'60',PROPELLER_SYNTH_ASSET_ID:String(r.synthAssetId),
 PROPELLER_ROUNDING_RESERVES:JSON.stringify(r.vaults.map(v=>v.rounding))});
const child=spawn(process.execPath,['--import','./propeller-vault/looper/node_modules/tsx/dist/loader.mjs','scripts/propeller/verify-readiness.ts'],{stdio:'inherit',env:process.env});
child.on('exit',code=>{process.exitCode=code??1;});
