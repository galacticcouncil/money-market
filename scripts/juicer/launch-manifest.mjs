// What the deployer-only launch deploys and records: the market it binds, the vaults it can create
// and the roles nobody but governance may hold. Pure; launch-deploy.mjs talks to the chain.
export const GOV='0xAa7e0000000000000000000000000000000Aa7e0';
// technical committee: GUARDIAN and the discount's RATE_ADMIN
export const COMMITTEE='0x146a5e57fa0b8b1e13c53bcf1d05183b1c02b51b';
export const POOL='0x1b02E051683b5cfaC5929C25E84adb26ECf87B38';
export const HOLLAR='0x531a654d1696ED52e7275A8cede955E82620f99a';
export const HOLLAR_DEBT='0x342923782cCaEBf9c38DD9cb40436e82C42c73B5';
export const DISPATCH='0x0000000000000000000000000000000000000401';
export const token=id=>`0x${(0x100000000n+BigInt(id)).toString(16).padStart(40,'0')}`;
export const SYNTH=['Juicer Synthetic HOLLAR','jsHOLLAR'];
// targetHf, deLeverTrigger; maxQuoteAge s, maxQuoteBlocks
export const LOOP=[1050000000000000000n,1100000000000000000n],QUOTES=[60n,5n];
// tvl caps in collateral base units; jBTC launches, jETH joins a later deployment with its own referendum
export const VAULTS={
 TBTC:{assetId:1000765,name:'Juicer BTC',symbol:'jBTC',cap:1337n*10n**15n},
 ETH:{assetId:4200,name:'Juicer ETH',symbol:'jETH',cap:10n*10n**18n},
};
export const ROLES=['DEFAULT_ADMIN_ROLE','ADMIN_ROLE','UPGRADER_ROLE','GUARDIAN_ROLE','MINTER_ROLE','VAULT_ROLE','KEEPER_ROLE','DEPOSIT_GUARDIAN_ROLE','RATE_ADMIN_ROLE'];
// the vault's ED-relative rounding reserve, as the lark deployments size it
export function roundingPolicy(vault,assetId,ed){
 ed=BigInt(ed);
 return {vault,assetId,minimum:(ed*2n+1000n).toString(),target:(ed*10n+1000000000n).toString()};
}
export function launchVaults(text='TBTC'){
 const names=text.split(',').map(s=>s.trim()).filter(Boolean);
 if(!names.length||new Set(names).size!==names.length)throw Error(`vaults "${text}": a comma list of ${Object.keys(VAULTS).join(', ')}`);
 return names.map(name=>{const p=VAULTS[name];if(!p)throw Error(`unknown vault ${name}`);return {key:name,...p};});
}
// verify-readiness.ts after enactment: the manifest's addresses and the plan's approved policy and values
export function readinessEnv(m,plan,{slippagePpm,ws,rpc}){
 const a=m.addresses,vaults=m.vaults.filter(x=>x.address);
 return {
  WS_URL:ws,RPC_URL:rpc,JUICER_SYNTH:a.synth,JUICER_SUBLOOP:a.subLoop,JUICER_HARVESTER:a.harvester,JUICER_VAULTS:vaults.map(x=>x.address).join(','),
  JUICER_EXECUTION_CONTROLLER:a.controller,JUICER_EXECUTION_POLICY:JSON.stringify(plan.policy),JUICER_SWAPPER:a.adapter,
  JUICER_FEE_CONTROLLER:a.fees,JUICER_FEE_RECIPIENT:m.market.treasury,JUICER_DISCOUNT_CONTROLLER:a.discount,JUICER_DISCOUNT_COMMITTEE:m.committee,
  JUICER_GUARDIAN:m.committee,JUICER_SLIPPAGE_PPM:String(slippagePpm),JUICER_ROUNDING_RESERVES:JSON.stringify(vaults.map(x=>x.rounding)),
  JUICER_COMPOUND_LOGIC_CODEHASH:m.deployments.find(d=>d.label==='CompoundLogic').codeHash,JUICER_KEEPERS:plan.keepers.join(','),
  JUICER_HARVEST_THRESHOLD:plan.values.harvestThreshold,JUICER_INTENT_TTL:String(plan.values.intentTtl),JUICER_INTENT_DRIFT_BPS:String(plan.values.intentDriftBps),
  JUICER_RESERVE_HOLLAR:plan.values.reserveHollar,JUICER_LOOP_DISCOUNT_CAP:plan.values.loopCapHollar,JUICER_SYNTH_ASSET_ID:String(plan.values.synthAssetId),
  JUICER_WITHDRAWAL_DELAY:String(plan.values.withdrawalDelay),JUICER_PRIME_POOL_FEE_PPM:String(plan.values.primePoolFeePpm),
  JUICER_REBALANCE_BAND:[plan.values.band.relever,plan.values.band.target,plan.values.band.delever].join(','),
  JUICER_ADMISSION_MAX_DEFICIT_BPS:String(plan.values.admissionMaxDeficitBps),
  JUICER_EXIT_HEADROOM:plan.values.exitHeadroom.enabled?`on,${plan.values.exitHeadroom.gapBps}`:'off',
  JUICER_PROTOCOL_FEE_BPS:String(plan.values.revenue.protocolFeeBps),JUICER_DISCOUNT_BPS:String(plan.values.revenue.mainDiscountBps),
  JUICER_LOOP_DISCOUNT_BPS:String(plan.values.revenue.loopDiscountBps),
 };
}
// node launch-manifest.mjs <manifest> <plan>: the readiness environment as shell exports (JUICER_SLIPPAGE_PPM, WS, RPC from the environment)
if(process.argv[1]&&import.meta.url.endsWith(process.argv[1].split('/').pop())&&process.argv[2]){
 const {readFileSync}=await import('node:fs');
 const [m,plan]=process.argv.slice(2,4).map(f=>JSON.parse(readFileSync(f,'utf8')));
 const env=readinessEnv(m,plan,{slippagePpm:process.env.JUICER_SLIPPAGE_PPM??plan.values.slippagePpm,ws:process.env.WS_URL??process.env.WS,rpc:process.env.RPC_URL??process.env.RPC});
 for(const [k,x]of Object.entries(env))console.log(`export ${k}='${x}'`);
}
