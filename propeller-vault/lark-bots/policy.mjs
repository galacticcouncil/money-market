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
