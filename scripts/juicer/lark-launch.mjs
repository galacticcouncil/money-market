// The mainnet launch process on a lark: launch-deploy.mjs's manifest and juicer.ts's plan in the lark
// journal's shape, so the lark-only steps after the referendum (inventory, depositors, manifest, stack)
// read the launch's contracts. Pure; lark-launch-adopt.mjs writes the journal.
import assert from 'node:assert/strict';
export function adoptLaunch(r,manifest,plan){
 assert.equal(manifest.kind,'juicer-launch','not a launch manifest');
 assert.equal(manifest.genesis,r.genesis,'the manifest belongs to another chain');
 const a=manifest.addresses,vaults=manifest.vaults.filter(x=>x.address);
 assert.ok(a.subLoop&&vaults.length,'the launch deploy has not finished');
 r.addresses={...r.addresses,compoundLogic:a.compoundLogic,vaultImpl:a.vaultImpl,synth:a.synth,subLogic:a.subLogic,subImpl:a.subImpl,
  source:a.subLoop,harvester:a.harvester,fees:a.fees,controller:a.controller,discount:a.discount,adapter:a.adapter};
 r.market={...r.market,...manifest.market,swapper:a.adapter};
 r.vaults=vaults.map(x=>({name:x.key,symbol:x.symbol,assetId:x.assetId,asset:x.asset,aToken:x.aToken,cap:x.cap,
  address:x.address,mainDebt:x.mainDebt,yieldAccounting:x.yieldAccounting,rounding:x.rounding}));
 r.feeRecipient=manifest.market.treasury;r.committee=manifest.committee;
 r.launch={...r.launch,deployer:manifest.deployer,prediction:manifest.prediction,checks:manifest.checks,deployments:manifest.deployments.length,calls:manifest.calls?.length??0};
 if(plan){
  r.executionPolicy=plan.policy;r.sourceSlippagePpm=plan.values.slippagePpm;r.synthAssetId=plan.values.synthAssetId;
  r.launch.values=plan.values;
  if(plan.proposal)r.launch.proposal={hash:plan.proposal.hash,len:plan.proposal.len,batches:plan.batches.length};
 }
 return r;
}
// what the rehearsal and the lark check in every block the launch referendum touched
export function failedEvent(section,method,data){
 const k=`${section}.${method}`;
 if(/^(evm\.ExecutedFailed|utility\.BatchInterrupted|utility\.ItemFailed|system\.ExtrinsicFailed|scheduler\.(CallUnavailable|PermanentlyOverweight|RetryFailed))$/.test(k))return true;
 const text=JSON.stringify(data);
 if(/^(scheduler\.Dispatched|dispatcher\.TreasuryManagerCallDispatched|utility\.DispatchedAs|dispatcher\.AaveManagerCallDispatched)$/.test(k))return /"err"/i.test(text);
 return /DispatchError/.test(text);
}
// the planned treasury buys among the enacted blocks' router.Executed rows: asset in, asset out, amount in, amount out
export function executedBuys(rows,buys=[]){
 return buys.map(b=>{
  const hit=rows.flatMap(x=>x.routerExecuted.map(e=>[x.block,...e])).find(([,i,o,,out])=>i===String(b.assetIn)&&o===String(b.assetOut)&&out===String(b.amountOut));
  return {...b,block:hit?.[0],amountIn:hit?.[3],withinBound:!!hit&&BigInt(hit[3])<=BigInt(b.maxAmountIn)};
 });
}
