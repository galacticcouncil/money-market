// One reviewed deployment per Lark genesis. Each chain is a profile: endpoints, pins,
// state files and the bots' identity, selected with --profile=<name> or LARK_PROFILE
// (default lark4). A profile's open (null) pins come from the environment until they
// are pinned here; never disable the identity checks that read these.
import assert from 'node:assert/strict';
import {join} from 'node:path';
import {LARK4_IDENTITY as L4} from './lark4-identity.mjs';
const SIGNERS={markets:'//Alice//propeller-20261005-arb',pools:'//Alice//propeller-20261007-pools',replay:'//Alice//propeller-20261007-replay'};
// the next version's parameters, as the mainnet proposal sets them (next-governance.ts)
export const NEXT_PARAMS={harvestThreshold:2n*10n**14n,reserve:1000n*10n**18n};
const BOTS={mirror:{BOT_INTERVAL_MS:'30000'},markets:{BOT_INTERVAL_MS:'5000',PEG_BAND_BPS:'0.5'},pools:{BOT_INTERVAL_MS:'30000'},replay:{BOT_INTERVAL_MS:'6000'}};
export const PROFILES={
 // the 7 october mainnet fork, #62 contracts; its operations keep running from here
 lark4:{
  legacy:true,
  chainName:'Lark 4 Hydration',
  genesis:'0x0a1fba23f7897cb5cbb3289db93ab605774565149b0c87033b4f2af817c9f96c',
  deployment:'20261007',
  commit:'db0799c2c13cfea880b089d737c02cfb2e116be6',
  rpc:'https://node4.lark.hydration.cloud',
  ws:'wss://node4.lark.hydration.cloud',
  // the saturated gateway: only the journal's identity, a keeper fallback and the readiness ws
  gateway:{rpc:'https://4.lark.hydration.cloud',ws:'wss://4.lark.hydration.cloud'},
  artifactDir:L4.artifactDir,
  adapterArtifact:'/tmp/hydra-augustus-london/HydraAugustus.sol/HydraAugustus.json',
  signers:SIGNERS,
  names:L4.names,
  hollarBucket:1000000,
  primeLanes:{trade:1000,capacity:10000,refill:10,pegPrime:150000,approval:'make sure the lark4 prime loop leveraging continues'},
  depositor:{durationS:259200,everyS:1800,delayS:null},
  // lark 4's real identities: its images, signers and files keep their names through the rename
  images:L4.images,statePrefix:L4.statePrefix,
  stack:{file:L4.stackFile,name:'propeller-oct2026',manifestConfig:'propeller-lark4-20261007-manifest-v3',keeperRpcUrls:['https://node4.lark.hydration.cloud','https://4.lark.hydration.cloud'],keeperEnv:{},bots:BOTS},
 },
 // the next version on Lark 0, reforked from mainnet after the rename; pin its genesis and
 // the contracts commit then (LARK_GENESIS and LARK_COMMIT fill them until that edit)
 lark0:{
  chainName:'Lark 0 Hydration',genesis:null,commit:null,
  deployment:'lark0-20261009',
  // 0.lark goes through subway: scripts stay on node0, keepers fall back to it as on lark 4
  rpc:'https://node0.lark.hydration.cloud',ws:'wss://node0.lark.hydration.cloud',
  // the merged next-version london build: JUICER_ARTIFACT_DIR, JUICER_ADAPTER_ARTIFACT
  artifactDir:null,adapterArtifact:null,
  // the same public dev derivations; separate chains share no state
  signers:SIGNERS,
  // the final names, as the rename gives mainnet
  names:{
   synth:['Juicer Synthetic HOLLAR','jsHOLLAR'],asset:'Juicer Synthetic HOLLAR',
   aToken:['Juicer aSynth','aJSYNTH'],variableDebt:['Juicer Variable Debt Synth','vdJSYNTH'],stableDebt:['Juicer Stable Debt Synth','sdJSYNTH'],
   vaults:{ETH:['Juicer ETH','jETH'],TBTC:['Juicer tBTC','jtBTC']},
  },
  hollarBucket:5000000,
  // one 2,500 HOLLAR trade a minute (60 s pacing; 50/s refills a trade in 50 s) buys the
  // ~400k PRIME the $100k plan levers into in under 3 h of trading, inside its 10 h window.
  // the peg's PRIME comes from the baseline seed round (400k) and prepare (100k)
  primeLanes:{trade:2500,capacity:25000,refill:50,pegPrime:0,approval:'faster PRIME entry lane than lark 4 so the loop levers within the deposit window'},
  // the $100k depositor plan in 10 h, one deposit per vault every 10 min, an hour after the stack
  depositor:{durationS:36000,everyS:600,delayS:3600},
  images:{keeper:'galacticcouncil/juicer-lark-keeper',bots:'galacticcouncil/juicer-lark-bots'},
  stack:{keeperRpcUrls:['https://node0.lark.hydration.cloud','https://0.lark.hydration.cloud'],keeperEnv:{QUOTE_DEPTH_BLOCKS:'3'},bots:BOTS},
 },
};
export function resolveProfile(name='lark4',env={}){
 const p=PROFILES[name];
 assert.ok(p,`unknown lark profile ${name} (${Object.keys(PROFILES).join(', ')})`);
 const open=(value,key)=>value??(env[key]||null);
 const chainName=open(p.chainName,'LARK_CHAIN_NAME'),rpc=open(p.rpc,'LARK_RPC'),ws=open(p.ws,'LARK_WS')??rpc?.replace(/^http/,'ws')??null;
 if(chainName)assert.match(chainName,/lark/i,'lark tooling never targets a non-lark chain');
 const dir=env.LARK_STATE_DIR||'/tmp',d=p.deployment,s=p.stack;
 const gateway=p.gateway??{rpc,ws};
 // lark 4's state files predate the rename and keep their names
 const prefix=p.statePrefix??'juicer';
 return Object.freeze({
  name,legacy:!!p.legacy,chainName,genesis:open(p.genesis,'LARK_GENESIS'),deployment:d,commit:open(p.commit,'LARK_COMMIT'),
  rpc,ws,gateway,
  journal:join(dir,`${prefix}-lark-${d}.json`),prices:join(dir,`${prefix}-lark-prices-${d}.json`),
  manifest:join(dir,`${prefix}-lark-manifest-${d}.json`),bringUp:join(dir,`${prefix}-lark-bringup-${d}.json`),
  artifactDir:p.artifactDir,adapterArtifact:p.adapterArtifact,
  signers:p.signers,names:p.names,hollarBucket:BigInt(p.hollarBucket)*10n**18n,
  primePool:p.primePool??{minDepthUsd:100000,targetDepthUsd:400000},primeLanes:p.primeLanes,depositor:p.depositor,images:p.images,
  stack:{
   file:join(dir,s.file??`juicer-lark-stack-${d}.json`),name:s.name??`juicer-${d}`,manifestConfig:s.manifestConfig??`juicer-${d}-manifest-v1`,
   keeperRpcUrls:s.keeperRpcUrls??[...new Set([rpc,gateway.rpc])].filter(Boolean),keeperEnv:s.keeperEnv,bots:s.bots,
   // lark 4's bots default to node4; any other chain hands them its endpoints
   botEnv:p.legacy?{}:{LARK_RPC:rpc,LARK_WS:ws},
  },
 });
}
// the chain-facing pins a script needs before it connects
export function requirePins(p=profile){
 const missing=[['chainName','LARK_CHAIN_NAME'],['genesis','LARK_GENESIS'],['rpc','LARK_RPC']].filter(([k])=>!p[k]).map(([,e])=>e);
 assert.equal(missing.length,0,`profile ${p.name} is not pinned: set ${missing.join(', ')} or pin them in lark-pins.mjs`);
 return p;
}
export const profile=resolveProfile(process.argv.find(a=>a.startsWith('--profile='))?.split('=')[1]??process.env.LARK_PROFILE??'lark4',process.env);
// native-artifacts reads these at import, so importers load this module first; the environment still wins
if(profile.artifactDir&&!process.env.JUICER_ARTIFACT_DIR)process.env.JUICER_ARTIFACT_DIR=profile.artifactDir;
if(profile.adapterArtifact&&!process.env.JUICER_ADAPTER_ARTIFACT)process.env.JUICER_ADAPTER_ARTIFACT=profile.adapterArtifact;
export const GENESIS=profile.genesis;
export const DEPLOYMENT=profile.deployment;
export const COMMIT=profile.commit;
export const CORE_FILE=profile.journal;
// price mirrors and the discount adapter journal separately (JUICER_LARK_RESULT=PRICES_FILE)
export const FILE=process.env.JUICER_LARK_RESULT||CORE_FILE;
export const PRICES_FILE=process.env.JUICER_LARK_PRICES||profile.prices;
export const MANIFEST_CONFIG=profile.stack.manifestConfig;
