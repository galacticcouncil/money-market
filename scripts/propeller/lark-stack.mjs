import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {mnemonicToAccount}=require('viem/accounts'),{toHex}=require('viem');
import {profile,requirePins,CORE_FILE as FILE,MANIFEST_CONFIG} from './lark-pins.mjs';
requirePins();
const r=JSON.parse(readFileSync(FILE,'utf8'));
assert.equal(r.rpc,profile.gateway.rpc);
assert.equal(r.genesis,profile.genesis);
const keeperImage=process.env.KEEPER_IMAGE,botImage=process.env.BOT_IMAGE;
assert.match(keeperImage??'',/^galacticcouncil\/propeller-lark-keeper@sha256:[0-9a-f]{64}$/);
assert.match(botImage??'',/^galacticcouncil\/propeller-lark-bots@sha256:[0-9a-f]{64}$/);
const stack=profile.stack,keepers=process.argv.includes('--keepers'),rpcs=stack.keeperRpcUrls,endpoints=stack.botEnv;
assert.ok(rpcs.length&&rpcs.every(Boolean),'keepers need the chain endpoint');
const common={stop_grace_period:'4m',logging:{driver:'json-file',options:{'max-size':'10m','max-file':'3'}},deploy:{replicas:1,update_config:{order:'stop-first',failure_action:'rollback'},restart_policy:{condition:'any',delay:'15s'},resources:{limits:{cpus:'0.50',memory:'512M'},reservations:{memory:'128M'}}}};
const services={};
for(const [index,accountIndex]of [[0,18],[1,20]]){
 const account=mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:accountIndex});
 // the profile retunes a variable in place or appends one
 const env=Object.assign({RPC_URL:rpcs[0],RPC_URLS:rpcs.join(','),LOOPER_PRIVATE_KEY:toHex(account.getHdKey().privateKey),SUBLOOP_ADDRESS:r.addresses.source,HARVESTER_ADDRESS:r.addresses.harvester,EXECUTION_CONTROLLER:r.addresses.controller,VAULT_ADDRESSES:r.vaults.map(v=>v.address).join(','),PROPELLER_ROUNDING_RESERVES:JSON.stringify(r.vaults.map(v=>v.rounding)),SPONSORED_GAS:'true',POLL_INTERVAL_MS:'30000',SAFETY_INTERVAL_MS:'30000',SLOW_EVERY:'2',OPERATOR_COUNT:'2',OPERATOR_INDEX:String(index),OPERATOR_SLOT_SECONDS:'60',HARVEST_MIN_USD8:'1000000',HARVEST_MAX_DELAY_SECONDS:'60',QUOTE_TTL_SECONDS:'60',QUOTE_DEPTH_BLOCKS:'3',MAX_TX_GAS:'16777216'},stack.keeperEnv);
 services[`keeper${index}`]={...common,image:keeperImage,environment:env,deploy:{...common.deploy,replicas:keepers?1:0}};
}
for(const [mode,env]of Object.entries(stack.bots))services[mode]={...common,image:botImage,environment:{BOT_MODE:mode,BOT_LIVE:'true',BOT_MANIFEST:'/app/manifest.json',...env,...endpoints},configs:[{source:'propeller_manifest',target:'/app/manifest.json'}]};
// the depositor only exists with an explicit --depositor and a fixed schedule start
if(process.argv.includes('--depositor')){
 assert.ok(/^\d+$/.test(process.env.DEPOSIT_START??''),'set DEPOSIT_START (unix seconds)');
 services.depositor={...common,image:botImage,environment:{BOT_MODE:'deposits',BOT_LIVE:'true',BOT_MANIFEST:'/app/manifest.json',BOT_INTERVAL_MS:'60000',DEPOSIT_START:process.env.DEPOSIT_START,DEPOSIT_DURATION_S:process.env.DEPOSIT_DURATION_S??'259200',DEPOSIT_EVERY_S:process.env.DEPOSIT_EVERY_S??'1800',DEPOSIT_USERS:'8',...endpoints},configs:[{source:'propeller_manifest',target:'/app/manifest.json'}]};
}
const compose={version:'3.8',services,configs:{propeller_manifest:{external:true,name:MANIFEST_CONFIG}}};
const file=stack.file;writeFileSync(file,JSON.stringify(compose,null,2)+'\n',{mode:0o600});
// a new chain's summary names its swarm stack; lark 4's stays as it was
console.log(JSON.stringify({file,keepers,genesis:r.genesis,keeperImage,botImage,services:Object.keys(services),...(profile.legacy?{}:{stack:stack.name,manifestConfig:MANIFEST_CONFIG})}));
