export const ceilDiv=(x,y)=>(x+y-1n)/y;
export function retainsQuoteInventory(balance,amount,price,decimals,reserveUsd8=100n*100000000n){
 return amount>0n&&amount<=balance&&price>0n
  &&(balance-amount)*price/10n**BigInt(decimals)>=reserveUsd8;
}
export function fairOutput(amount,priceIn,priceOut,decimalsIn,decimalsOut){
 if(amount<=0n||priceIn<=0n||priceOut<=0n)throw Error('nonpositive pricing input');
 return amount*priceIn*10n**BigInt(decimalsOut)/(priceOut*10n**BigInt(decimalsIn));
}
export function profitableQuote({amount,out,fair,edgeBps=2n,driftBps=2n}){
 if(amount<=0n||out<=0n||fair<=0n||edgeBps<0n||driftBps<0n||driftBps>=10000n)return null;
 const oracleMinimum=ceilDiv(fair*(10000n+edgeBps),10000n);
 if(out<oracleMinimum)return null;
 const quoteMinimum=out*(10000n-driftBps)/10000n;
 return {amount,out,fair,minOut:oracleMinimum>quoteMinimum?oracleMinimum:quoteMinimum,edgeBps:(out-fair)*10000n/fair};
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
// top-level mainnet trades per extrinsic or hook phase; inner legs of a routed trade are skipped
export function replayTrades(groups){
 const out=[];
 for(const events of groups){
  const routed=events.filter(e=>e.name==='router.Executed');
  if(routed.length){for(const e of routed)out.push({input:e.input,output:e.output,amount:e.amount,route:null});continue;}
  for(const e of events){
   if(e.name==='omnipool.SellExecuted'||e.name==='omnipool.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:'Omnipool',assetIn:e.input,assetOut:e.output}]});
   else if(e.name==='stableswap.SellExecuted'||e.name==='stableswap.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:{Stableswap:e.pool},assetIn:e.input,assetOut:e.output}]});
   else if(e.name==='xyk.SellExecuted'||e.name==='xyk.BuyExecuted')out.push({input:e.input,output:e.output,amount:e.amount,route:[{pool:'XYK',assetIn:e.input,assetOut:e.output}]});
  }
 }
 return out.filter(t=>t.amount>0n&&t.input!==t.output);
}
