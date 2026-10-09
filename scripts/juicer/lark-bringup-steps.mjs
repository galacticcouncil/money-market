// The new-Lark bring-up, in order. Each step is an existing (or new) step script whose
// completion is read back from the deployment journals, so a rerun resumes where it stopped.
const gov=(s,label)=>!!s.core?.governance?.some(g=>g.label===label&&g.verified);
const check=(s,name)=>!!s.core?.checks?.[name];
export const STEPS=[
 {id:'chain',script:'lark-chain-check.mjs',what:'preflight: runtime 447+ with ICE, money-market reserves and oracles, pool 143 route, synthetic asset id, facilitator',done:s=>check(s,'chain')},
 {id:'prepare',script:'lark-prepare.mjs',what:'isolated test accounts (deployer, keeper, arb), contract deployer whitelist',done:s=>check(s,'testAccountsFunded')},
 {id:'prime-pool',script:'lark-prime-pool.mjs',what:'PRIME stableswap pool 143 depth; a shallow pool gets liquidity at its ratio (creates the HOLLAR facilitator bucket)',done:s=>check(s,'primePool')},
 {id:'deploy',script:'lark-deploy.mjs',live:true,needs:['adapter'],what:'HydraAugustus adapter, implementation, synthetic, source, harvester, fees, controller, both vaults and Main ledgers',done:s=>s.core?.vaults?.length===2&&s.core.vaults.every(x=>x.rounding)},
 {id:'wire',script:'lark-wire.mjs',what:'synthetic asset and money-market reserve listing, source, vaults, custody, execution budgets and lanes, controller',done:s=>gov(s,'bind-execution-controller')},
 {id:'prices',script:'lark-prices-deploy.mjs',live:true,journal:'prices',what:'ManagedOracle mirrors of the mainnet ETH, tBTC and PRIME feeds',done:s=>s.prices?.oracles?.length===3},
 {id:'discount',script:'lark-discount-deploy.mjs',live:true,journal:'prices',what:'zero-discount JuicerDiscount',done:s=>!!s.prices?.addresses?.discount},
 {id:'market',script:'lark-market-setup.mjs',what:'zero discount, mirror price sources, pool 143 peg on the PRIME mirror, bot and UI funding, arb binding and HOLLAR, guardians, open bootstrap',done:s=>gov(s,'testnet-guardians-and-open-bootstrap')},
 {id:'bootstrap',script:'lark-bootstrap.mjs',what:'bootstrap deposits without borrowing, temporary admin revoked',done:s=>check(s,'bootstrapNoBorrow')},
 {id:'prime-cap',script:'lark-approve-prime-cap.mjs',what:'6 bps PRIME lanes, waits for the pool 143 peg, restores its pacing, arb HOLLAR reserve',done:s=>gov(s,'arb.refill-hollar-with-quote-reserve')},
 {id:'adapter',script:'lark-protect-adapter.mjs',what:'duster protection for the adapter',done:s=>check(s,'adapterWhitelisted')},
 {id:'routes',script:'lark-routes-setup.mjs',what:'PRIME to ETH/tBTC routes through pool 143',done:s=>check(s,'primeCollateralRoutes')},
 {id:'harvest-cap',script:'lark-approve-harvest-cap.mjs',what:'100 bps collateral lanes and compound floor (Lark only)',done:s=>gov(s,'approved-lark-only-collateral-hundred-bps')},
 {id:'throughput',script:'lark-prime-throughput.mjs',what:'PRIME lanes and source tranches at the profile\'s trade size (Lark 0: 2,500 a trade, 50/s)',done:s=>gov(s,`lark-prime-tranches-${s.profile.primeLanes.trade}`)},
 {id:'sync',script:'lark-mainnet-sync-setup.mjs',what:'mainnet feeds to the mirror signer, pools and replay inventory, EVM bindings and HOLLAR',done:s=>check(s,'mainnetSync')},
 {id:'sync-inventory',script:'lark-mainnet-sync-inventory.mjs',what:'replay long tail and EVM-token inventory',done:s=>check(s,'syncInventory')},
 {id:'wrap',script:'lark-wrap-inventory.mjs',what:'pools aTokens wrapped from minted underlying, plus its stash',done:s=>gov(s,'pools-underlying-stash')},
 {id:'stable',script:'lark-stable-inventory.mjs',what:'both sides of every stableswap pool the pools bot corrects',done:s=>gov(s,'pools-stable-inventory')},
 {id:'release',script:'lark-release-deposits.mjs',what:'test mints the deposit fuse parked, released; GSOL for pools',done:s=>check(s,'depositRelease')},
 {id:'seed',script:'lark-seed-bots.mjs',args:['--round=baseline'],what:'what the Lark 4 bots reported missing, minted up front',done:s=>gov(s,'bots-seed-baseline')},
 {id:'params',script:'lark-next-params.mjs',what:'harvest threshold 2e14, 1,000 HOLLAR protocol reserve per vault',done:s=>check(s,'nextParameters')},
 {id:'guardian',script:'lark-deposit-guardian.mjs',what:'DEPOSIT_GUARDIAN_ROLE (setDeficitStop only) for both keepers on both vaults',done:s=>check(s,'depositGuardian')},
 {id:'ice',script:'lark-ice-wiring.mjs',what:'ICE: 300 s intents with 2 bps drift, KEEPER_ROLE for both keepers, async entry and unwind lanes, WETH for the callback fee',done:s=>check(s,'iceWiring')},
 {id:'depositors',script:'lark-depositor-setup.mjs',what:'eight public test depositors with ~$100k of test ETH and tBTC, TVL caps to fit',done:s=>check(s,'depositorFunded')},
 {id:'depositor-approve',script:'lark-depositor-approve.mjs',what:'each depositor approves both vaults (u128 max, all the precompile takes)',done:s=>check(s,'depositorApproved')},
 {id:'manifest',script:'lark-manifest.mjs',output:true,what:'bot manifest for the swarm config, depositor plan included'},
 {id:'stack',script:'lark-stack.mjs',args:['--keepers','--depositor'],output:true,needs:['images'],what:'swarm stack: keepers on, depositor an hour after it is written'},
];
export function stepStatus(step,state){
 if(step.output)return 'output';
 return step.done(state)?'done':'pending';
}
// what a run does next: the first step to run, skip or stop at
export function schedule(steps,state,{live=false,only,from,skip=new Set(),ran=new Set()}={}){
 let started=!from;
 for(const step of steps){
  if(!started&&step.id!==from)continue;
  started=true;
  if(ran.has(step.id)||(only&&step.id!==only))continue;
  const status=stepStatus(step,state);
  if(status==='done'&&!only)continue;
  if(step.output){if(live)return {run:step};continue;}
  if(skip.has(step.id))return {skip:step};
  if(!live&&step.live)return {stop:step,reason:'has no dry run; it runs with --live'};
  return {run:step};
 }
 return null;
}
// what must be set before a step can start
export function missing(step,profile,env){
 const out=[];
 const pins=[['chainName','LARK_CHAIN_NAME'],['genesis','LARK_GENESIS'],['rpc','LARK_RPC']].filter(([k])=>!profile[k]).map(([,e])=>e);
 out.push(...pins);
 if(step.id==='chain'&&!profile.commit)out.push('LARK_COMMIT');
 if(!step.output&&!env.JUICER_ARTIFACT_DIR&&!profile.artifactDir)out.push('JUICER_ARTIFACT_DIR');
 if(step.needs?.includes('adapter')&&!env.JUICER_ADAPTER_ARTIFACT&&!profile.adapterArtifact)out.push('JUICER_ADAPTER_ARTIFACT');
 if(step.needs?.includes('images'))for(const [name,repo]of [['KEEPER_IMAGE','keeper'],['BOT_IMAGE','bots']])if(!new RegExp(`^${profile.images[repo]}@sha256:[0-9a-f]{64}$`).test(env[name]??''))out.push(name);
 return out;
}
