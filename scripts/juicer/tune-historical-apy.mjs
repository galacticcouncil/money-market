// Four sequential rounds: baseline, size/bounds, cadence, held-out validation.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {loadMath,poolQuote} from './pressure-model.mjs';
import {prepare,simulate,regimeWindows,BASE_POLICY,selectPolicy,asPool} from './historical-apy-model.mjs';
const [input,output='/tmp/juicer-historical-campaign'] = process.argv.slice(2);
assert.ok(input,'usage: tune-historical-apy.mjs history.json output-directory');
mkdirSync(output,{recursive:true});
const bytes=readFileSync(input),history=JSON.parse(bytes),math=loadMath(process.env.HYDRATION_MATH_ROOT);
const rows=prepare(history,math),split=history.start+60*86400;
const train=rows.filter(r=>r.t<split),test=rows.filter(r=>r.t>=split),assets=['ETH','BTC'];
const cases=[];
function run(round,label,period,policy,mode='observed',tvl=10000) {
  const results=assets.map(asset=>simulate(period,math,asset,policy,mode,tvl));
  for(const r of results)cases.push({round,label,...r});
  const scored=results.map(r=>r.liquidatable?-Infinity:
    r.fundedCryptoReturnPct-100*r.backingDeficitUsd/(r.tvl*(1+r.priceReturnPct/100)));
  const score=scored.reduce((a,b)=>a+b,0)/2;
  const second=results.reduce((a,r)=>a+r.unconvertedUserUsd/(r.tvl*(1+r.priceReturnPct/100)),0)/2;
  return {label,policy,score,unconvertedTieBreaker:second,
    meanFundedPct:results.reduce((n,r)=>n+r.fundedCryptoReturnPct,0)/2};
}
const rounds=[];
run(1,'baseline-90d',rows,{});
run(1,'perfect-90d',rows,{},'perfect');
const incumbent=run(1,'baseline-training',train,{...BASE_POLICY});
rounds.push({round:1,purpose:'Historical baseline and same-history ideal-arbitrage comparison',cases:6});
console.log('round 1 complete');
const sizes=[];
for(const size of [100,1000,8000])for(const sourceLimitBps of [8,18,48,98]) {
  const p={...BASE_POLICY,size,sourceLimitBps,sourceReserveBps:sourceLimitBps+2};
  sizes.push(run(2,`size-${size}-limit-${sourceLimitBps}`,train,p));
}
const sizeSelection=selectPolicy(sizes,incumbent),sizeWinner=sizeSelection.winner;
rounds.push({round:2,purpose:'Trade sizes and oracle-loss ceilings on the first 60 days only',candidates:sizes,...sizeSelection});
console.log('round 2 complete',sizeWinner);
const controls=[];
for(const thresholdBps of [1,10,30])for(const minHarvest of [1,10])
  for(const entryEveryHours of [0,6,24])for(const adaptive of [false,true]) {
    const p={...sizeWinner.policy,thresholdBps,minHarvest,entryEveryHours,harvestEveryHours:entryEveryHours,adaptive};
    controls.push(run(3,`threshold-${thresholdBps}-minimum-${minHarvest}-cadence-${entryEveryHours}-adaptive-${adaptive}`,train,p));
  }
const controlSelection=selectPolicy(controls,sizeWinner),controlWinner=controlSelection.winner;
rounds.push({round:3,purpose:'Fresh sampled quotes, adaptive sizing, harvest thresholds and entry cadence',candidates:controls,...controlSelection});
console.log('round 3 complete',controlWinner);
run(4,'baseline-holdout',test,{});
run(4,'selected-holdout',test,controlWinner.policy);
run(4,'selected-90d',rows,controlWinner.policy);
run(4,'selected-perfect-90d',rows,controlWinner.policy,'perfect');
run(4,'selected-no-refill-90d',rows,controlWinner.policy,'none');
run(4,'adaptive-diagnostic-90d',rows,{...controlWinner.policy,adaptive:true});
run(4,'adaptive-diagnostic-holdout',test,{...controlWinner.policy,adaptive:true});
run(4,'adaptive-perfect-diagnostic-90d',rows,{...controlWinner.policy,adaptive:true},'perfect');
// Held-out diagnostics are not fed back into the frozen training selection.
for(const size of [100,1000,8000])run(4,`holdout-size-sensitivity-${size}`,test,{...controlWinner.policy,size});
for(const tailBps of [0,25,100])run(4,`tail-sensitivity-${tailBps}`,rows,{...controlWinner.policy,tailBps});
for(const tvl of [100000,1000000])run(4,`capital-sensitivity-${tvl}`,rows,controlWinner.policy,'observed',tvl);
const regimes=regimeWindows(history,split);
for(const w of regimes)run(4,`fresh-${w.name}`,rows.filter(r=>r.t>=w.from&&r.t<w.to),controlWinner.policy);
rounds.push({round:4,purpose:'Frozen policy: held-out final 30 days, complete 90 days, liquidity/route/capital sensitivities and actual regimes',
  policyFrozenBeforeHoldout:true,regimes,selectionChangedAfterHoldout:false});
console.log('round 4 complete',cases.length,'independent asset scenarios');
const marketSummary={points:rows.length,from:history.from,toExclusive:history.to,
  firstObservation:rows[0].t,lastObservation:rows.at(-1).t,
  trainingEndExclusive:new Date(split*1000).toISOString(),
  maxObservationGapMinutes:Math.max(...rows.slice(1).map((r,i)=>(r.t-rows[i].t)/60)),
  primeOracleChangePct:100*(rows.at(-1).prices[2]/rows[0].prices[2]-1),
  primeSupplyIndexChangePct:100*(rows.at(-1).income/rows[0].income-1),
  borrowIndexChangePct:100*(rows.at(-1).debt/rows[0].debt-1),
  entryQuoteCoverage:[100,1000,8000].map(size=> {
    const losses=rows.map(r=>(1-Number(poolQuote(math.stable,asPool(r),222,43,BigInt(size)*10n**18n))/1e6*r.prices[2]/size)*10000).sort((a,b)=>a-b);
    return {size,observations:losses.length,within8Bps:losses.filter(x=>x<=8).length,
      medianLossBps:losses[Math.floor(losses.length/2)],minLossBps:losses[0],maxLossBps:losses.at(-1)};
  }),
  oracleUpdates:rows.flatMap((r,i)=>i&&r.prices[2]!==rows[i-1].prices[2]?
    [{block:r.block,t:r.t,previous:rows[i-1].prices[2],price:r.prices[2]}]:[]),
  missingCandles:Object.fromEntries(assets.map(a=>{
    const ts=new Set(history.candles[a].map(x=>x.intervalStart)),missing=[];
    for(let t=history.start;t<history.end;t+=3600)if(!ts.has(t))missing.push(t);
    return [a,missing];
  }))};
const result={model:'Single-depositor economic approximation; not contract or executable keeper replay',
  inputSha256:createHash('sha256').update(bytes).digest('hex'),dependencies:math.dependencies,
  objective:'Funded crypto return minus terminal backing deficit, both in initial crypto units; externally funded gas',
  sharedOperatingBudgetUsdMonthly:10,operatingBudgetChargedToUsers:0,
  marketSummary,rounds,cases,
  limitations:[
    'Counterfactual current Juicer policy on historical market inputs; no Juicer deployment existed in these observations.',
    'Single depositor and one isolated vault per scenario; ETH/BTC cases do not both claim this same pool capacity simultaneously.',
    'Exact archive oracle/index values and exact sampled pool states; background reserve deltas are exogenous and our own cumulative impacts persist.',
    'Oracle catch-up gains are marked when observed; this is not a continuously realizable source APR or a forecast of future APY.',
    'PRIME pool swap fee, peg dislocation and price impact use official math. Remaining crypto/service route haircuts are assumptions, not historical full-route quotes.',
    'Stored peg/fee inputs are quoted as observed; runtime peg refresh and dynamic fee adjustments during actual dispatch are not reproduced.',
    'Perfect arbitrage resets to the oracle-fair marginal price before every trade using unlimited external arbitrage; same fees and within-trade impact remain.',
    'No-refill freezes initial reserve inventory while retaining observed peg/fee/oracle/index changes; it is a sensitivity, not an observed period.',
    'Freshness means a new mathematical quote at each sampled block; inclusion latency, native circuit breakers and live executability are not simulated.',
    'Synthetic Main safety floor is assumed; source liquidation is flagged, not modeled as a profitable/successful scenario.',
    'Yield ownership, rebalance commitments, servicing overpayment and liquidation details are economic approximations; this does not replace the real-contract validation campaign.',
    'End values retain the strategy. Full exit costs and liquidation penalties are not deducted.',
    'Collateral reserve supply interest is not credited; funded returns measure the additional PRIME strategy carry, not total vault income.',
    'Only modest actual drawdowns exist in this 90-day window. This is not a severe or prolonged bear-market stress test.',
    'Training selection uses the first 60 days only; held-out diagnostics do not retune it. Short-window annualization is descriptive, not forecast.'
  ]};
writeFileSync(resolve(output,'analysis.json'),JSON.stringify(result,null,2)+'\n');
const fields=['round','label','asset','mode','days','fundedCryptoReturnPct','annualizedFundedCryptoPct','fundedCryptoUsd','unconvertedUserUsd','backingDeficitUsd','unadmittedInitialPct','totalTradingLossUsd','firstDeposit','firstCrypto','entryTrades','harvests'];
writeFileSync(resolve(output,'cases.csv'),[fields.join(','),...cases.map(r=>fields.map(k=>r[k]??'').join(','))].join('\n')+'\n');
console.log(JSON.stringify(marketSummary,null,2));
