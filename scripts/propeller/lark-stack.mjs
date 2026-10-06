import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {mnemonicToAccount}=require('viem/accounts'),{toHex}=require('viem');
const r=JSON.parse(readFileSync('/tmp/propeller-lark-20261005.json','utf8'));
assert.equal(r.rpc,'https://4.lark.hydration.cloud');
assert.equal(r.genesis,'0xba82f5b6d812fd3e2a6c610969e395d3be1e558145a9f07148b8d1f269ab4fb2');
const keeperImage=process.env.KEEPER_IMAGE,botImage=process.env.BOT_IMAGE;
assert.match(keeperImage??'',/^galacticcouncil\/propeller-lark-keeper@sha256:[0-9a-f]{64}$/);
assert.match(botImage??'',/^galacticcouncil\/propeller-lark-bots@sha256:[0-9a-f]{64}$/);
const keepers=process.argv.includes('--keepers');
const common={restart:'unless-stopped',stop_grace_period:'4m',logging:{driver:'json-file',options:{'max-size':'10m','max-file':'3'}},deploy:{replicas:1,update_config:{order:'stop-first',failure_action:'rollback'},restart_policy:{condition:'any',delay:'15s'},resources:{limits:{cpus:'0.50',memory:'512M'},reservations:{memory:'128M'}}}};
delete common.restart; // Swarm uses deploy.restart_policy.
const services={};
for(const [index,accountIndex]of [[0,18],[1,20]]){
 const account=mnemonicToAccount('test test test test test test test test test test test junk',{addressIndex:accountIndex});
 const env={RPC_URL:'https://node4.lark.hydration.cloud',RPC_URLS:'https://node4.lark.hydration.cloud,https://4.lark.hydration.cloud',LOOPER_PRIVATE_KEY:toHex(account.getHdKey().privateKey),SUBLOOP_ADDRESS:r.addresses.source,HARVESTER_ADDRESS:r.addresses.harvester,EXECUTION_CONTROLLER:r.addresses.controller,VAULT_ADDRESSES:r.vaults.map(v=>v.address).join(','),PROPELLER_ROUNDING_RESERVES:JSON.stringify(r.vaults.map(v=>v.rounding)),SPONSORED_GAS:'true',POLL_INTERVAL_MS:'30000',SAFETY_INTERVAL_MS:'30000',SLOW_EVERY:'2',OPERATOR_COUNT:'2',OPERATOR_INDEX:String(index),OPERATOR_SLOT_SECONDS:'60',HARVEST_MIN_USD8:'1000000',HARVEST_MAX_DELAY_SECONDS:'60',QUOTE_TTL_SECONDS:'60',MAX_TX_GAS:'16777216'};
 services[`keeper${index}`]={...common,image:keeperImage,environment:env,deploy:{...common.deploy,replicas:keepers?1:0}};
}
for(const mode of ['mirror','markets'])services[mode]={...common,image:botImage,environment:{BOT_MODE:mode,BOT_LIVE:'true',BOT_MANIFEST:'/app/manifest.json',BOT_INTERVAL_MS:mode==='markets'?'5000':'30000'},configs:[{source:'propeller_manifest',target:'/app/manifest.json'}]};
const compose={version:'3.8',services,configs:{propeller_manifest:{external:true,name:'propeller-oct2026-manifest-v1'}}};
const file='/tmp/propeller-lark-stack.json';writeFileSync(file,JSON.stringify(compose,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({file,keepers,genesis:r.genesis,keeperImage,botImage,services:Object.keys(services)}));
