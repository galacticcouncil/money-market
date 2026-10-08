const ceilDiv=(x,y)=>(x+y-1n)/y;
export function fairOutput(amount,priceIn,priceOut,decimalsIn,decimalsOut){
 if(amount<=0n||priceIn<=0n||priceOut<=0n)throw Error('nonpositive pricing input');
 return amount*priceIn*10n**BigInt(decimalsOut)/(priceOut*10n**BigInt(decimalsIn));
}
// pool premium over the oracle in 1/100 bps: half the buy/sell cost gap cancels the pool fee
export function pegPremium({buyOut,buyFair,sellOut,sellFair}){
 if(buyFair<=0n||sellFair<=0n)throw Error('nonpositive pricing input');
 return ((buyFair-buyOut)*1000000n/buyFair-(sellFair-sellOut)*1000000n/sellFair)/2n;
}
// largest input, to ~1/1024 of `max`, that moves a price toward `target` without crossing it
export async function sizeToTarget(priceAfter,before,max,target=0n){
 if(max<=0n||before===target)return 0n;
 const crossed=p=>before>target?p<target:p>target;
 if(!crossed(await priceAfter(max)))return max;
 let lo=0n,hi=max;const step=max/1024n;
 while(hi-lo>step&&hi-lo>1n){const mid=(lo+hi)/2n;if(crossed(await priceAfter(mid)))hi=mid;else lo=mid;}
 return lo;
}
// a peg trade may pay the pool fee, never more than `maxLossBps` under the oracle
export function pegMinOut({out,fair,maxLossBps=5n,driftBps=2n}){
 if(out<=0n||fair<=0n||maxLossBps<0n||driftBps<0n||driftBps>=10000n)return null;
 const floor=ceilDiv(fair*(10000n-maxLossBps),10000n);
 if(out<floor)return null;
 const quoteMinimum=out*(10000n-driftBps)/10000n;
 return quoteMinimum>floor?quoteMinimum:floor;
}
export function freshReference({price,updatedAt,chainTime,headAge,maxAge=86400n}){
 return price>0n&&updatedAt>0n&&updatedAt<=chainTime&&chainTime-updatedAt<=maxAge&&headAge>=-30&&headAge<=120;
}
export function orientRoute(route,input,output){
 if(!route.length)return [];
 const out=route.map(h=>({...h}));
 if(Number(out[0].assetIn)!==input){out.reverse();for(const h of out)[h.assetIn,h.assetOut]=[h.assetOut,h.assetIn];}
 if(Number(out[0].assetIn)!==input||Number(out.at(-1).assetOut)!==output)throw Error('route endpoints do not match');
 for(let i=1;i<out.length;i++)if(Number(out[i-1].assetOut)!==Number(out[i].assetIn))throw Error('disconnected route');
 return out;
}
const SCALE=10n**18n;
// asset price in the anchor (both omnipool sub-pools of {hub,res}), scaled by 1e18
export function omnipoolRatio(asset,anchor){
 if(asset.res<=0n||anchor.hub<=0n)throw Error('empty omnipool side');
 return asset.hub*anchor.res*SCALE/(asset.res*anchor.hub);
}
// fee-free constant-product hop through the hub: sell `amount` of the asset (or the anchor)
export function omnipoolAfter(asset,anchor,sellAsset,amount){
 const [from,to]=sellAsset?[asset,anchor]:[anchor,asset];
 const fromHub=from.hub*from.res/(from.res+amount),hub=from.hub-fromHub;
 const next={from:{hub:fromHub,res:from.res+amount},to:{hub:to.hub+hub,res:to.res*to.hub/(to.hub+hub)}};
 return sellAsset?omnipoolRatio(next.from,next.to):omnipoolRatio(next.to,next.from);
}
// smallest input that brings the asset/anchor ratio to `target`, capped at `max`
export function sizeOmnipoolTrade(asset,anchor,target,max){
 const ratio=omnipoolRatio(asset,anchor);
 if(ratio===target||max<=0n)return {sellAsset:ratio>target,amount:0n};
 const sellAsset=ratio>target;
 let lo=0n,hi=max;
 if(sellAsset?omnipoolAfter(asset,anchor,true,hi)>target:omnipoolAfter(asset,anchor,false,hi)<target)return {sellAsset,amount:hi};
 for(let i=0;i<128&&hi-lo>1n;i++){
  const mid=(lo+hi)/2n,after=omnipoolAfter(asset,anchor,sellAsset,mid);
  if(sellAsset?after>target:after<target)lo=mid;else hi=mid;
 }
 return {sellAsset,amount:hi};
}
export function deviationBps(lark,main){return (lark-main)*10000n/main;}
// deviation a trade removes; a short-inventory asset must not starve the others
export function correctionGainBps(asset,anchor,target,sellAsset,amount){
 if(amount===0n)return 0n;
 const abs=x=>x<0n?-x:x;
 return abs(deviationBps(omnipoolRatio(asset,anchor),target))-abs(deviationBps(omnipoolAfter(asset,anchor,sellAsset,amount),target));
}
// what the straight-line schedule owes now, net of what was already deposited
export function depositOwed({total,remaining,start,duration,now}){
 const elapsed=now<=start?0n:now-start<duration?now-start:duration;
 return total*elapsed/duration-(total-remaining);
}
// a user-like size: log-uniform 0.2-5x the average slot, kept within one slot of the schedule
export function userDeposit({owed,slot,rand}){
 const cap=owed+slot;
 if(cap<=0n)return 0n;
 const draw=BigInt(Math.floor(Number(slot)*0.2*25**rand()));
 const size=draw<cap?draw:cap;
 return size*10n<slot?0n:size;
}
const FILLERS={Omnipool:'Omnipool',XYK:'XYK',LBP:'LBP',AAVE:'Aave',HSM:'HSM'};
// rebuild a router route from its per-hop broadcast.Swapped3 legs; omnipool hops pass through the hub
export function swapRoute(legs,input,output){
 const route=[];
 for(const l of legs){
  const pool=l.filler?.Stableswap!==undefined?{Stableswap:l.filler.Stableswap}:FILLERS[l.filler];
  if(!pool)return null;
  const last=route.at(-1);
  if(pool==='Omnipool'&&last?.pool==='Omnipool'&&last.assetOut===1&&l.input===1){last.assetOut=l.output;continue;}
  route.push({pool,assetIn:l.input,assetOut:l.output});
 }
 const linked=route.every((h,i)=>i===0||route[i-1].assetOut===h.assetIn);
 return route.length&&linked&&route[0].assetIn===input&&route.at(-1).assetOut===output?route:null;
}
// top-level mainnet trades per extrinsic; routed trades keep the hops they took
export function replayTrades(groups){
 const out=[];
 for(const events of groups){
  if(events.some(e=>e.name==='router.Executed')){
   let legs=[];
   for(const e of events){
    if(e.name==='broadcast.Swapped3')legs.push(e);
    else if(e.name==='router.Executed'){out.push({input:e.input,output:e.output,amount:e.amount,route:swapRoute(legs,e.input,e.output)});legs=[];}
   }
   continue;
  }
  for(const e of events){
   if(e.name==='omnipool.SellExecuted'||e.name==='omnipool.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:'Omnipool',assetIn:e.input,assetOut:e.output}]});
   else if(e.name==='stableswap.SellExecuted'||e.name==='stableswap.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:{Stableswap:e.pool},assetIn:e.input,assetOut:e.output}]});
   else if(e.name==='xyk.SellExecuted'||e.name==='xyk.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:'XYK',assetIn:e.input,assetOut:e.output}]});
  }
 }
 return out.filter(t=>t.amount>0n&&t.input!==t.output);
}
// a v3 manifest (lark 4) predates the chain identity fields
const LARK4={chainName:'Lark 4 Hydration',signers:{markets:'//Alice//propeller-20261005-arb',pools:'//Alice//propeller-20261007-pools',replay:'//Alice//propeller-20261007-replay'}};
export function botIdentity(manifest){
 const id={chainName:manifest.chainName??LARK4.chainName,signers:{...LARK4.signers,...manifest.signers}};
 if(!/lark/i.test(id.chainName))throw Error(`not a lark chain: ${id.chainName}`);
 return id;
}
