import test from 'node:test';
import assert from 'node:assert/strict';
import {loadMath} from './pressure-model.mjs';
import {PoolReplay,asPool,equilibrate,simulate,prepare,regimeWindows,selectPolicy} from './historical-apy-model.mjs';
const math=process.env.HYDRATION_MATH_ROOT?loadMath(process.env.HYDRATION_MATH_ROOT):null;
const mathTest=(name,fn)=>test(name,{skip:!math&&'Set HYDRATION_MATH_ROOT to run official-SDK integration tests'},fn);
const point=(t=0)=>({t,block:t+1,hash:'0x'+String(t),reserves:['500000000000','500000000000000000000000'],
  pegs:[{num:'1',den:'1'},{num:'1',den:'1'}],amplification:100,feePermill:400,
  prices:[2000,80000,1,1],income:1,debt:1,issuance:'1000'});
function row(t,overrides={}) {const r={...point(t),...overrides};r.ideal=equilibrate(math.stable,asPool(r),r.prices[2]);return r;}

mathTest('own price impact survives a repeated historical state and elapsed time',()=>{
  const p=new PoolReplay(math.stable,'observed'),r=row(0);p.observe(r,1,r.ideal);
  const first=p.quote(true,8000);p.execute(true,first);const after=p.quote(true,8000);
  p.observe(row(3600),1,r.ideal);assert.deepEqual(p.quote(true,8000),after);
  assert.ok(after.output<first.output);assert.ok(p.poolFees>3);
});
mathTest('observed opposite flow is additive, not a free reset of our trade',()=>{
  const p=new PoolReplay(math.stable,'observed'),r=row(0);p.observe(r,1,r.ideal);
  const q=p.quote(true,1000);p.execute(true,q);
  const next=row(3600);next.reserves=[(BigInt(r.reserves[0])+q.out).toString(),(BigInt(r.reserves[1])-q.raw).toString()];
  p.observe(next,1,next.ideal);assert.deepEqual(p.state().reserves,asPool(r).reserves);
  p.observe(next,1,next.ideal);assert.deepEqual(p.state().reserves,asPool(r).reserves);
});
mathTest('perfect arbitrage removes between-trade impact but preserves fees',()=>{
  const p=new PoolReplay(math.stable,'perfect'),r=row(0);p.observe(r,1,r.ideal);
  const q=p.quote(true,1000);p.execute(true,q);assert.deepEqual(p.quote(true,1000),q);
  assert.ok(q.output<q.input);assert.ok(p.poolFees>.39);
});
mathTest('ideal arbitrage restores fair marginal quotes on both sides of imbalance',()=>{
  for(const reserves of [['200000000000','800000000000000000000000'],['800000000000','200000000000000000000000']]) {
    const r=row(0,{reserves}),p=new PoolReplay(math.stable,'perfect');p.observe(r,1,r.ideal);
    const buy=p.quote(true,1),sell=p.quote(false,1);
    assert.ok(Math.abs(buy.output-.9996)<.00002);assert.ok(Math.abs(sell.output-.9996)<.00002);
  }
});
mathTest('crypto price gains are not earned crypto, and rejected quotes create no debt',()=>{
  const rows=[row(0),row(86400,{prices:[4000,160000,1,1]})];
  const r=simulate(rows,math,'ETH',{sourceLimitBps:0},'observed');
  assert.equal(r.priceReturnPct,100);assert.equal(r.fundedCryptoReturnPct,0);
  assert.equal(r.mainDebtUsd,0);assert.equal(r.entryTrades,0);assert.equal(r.unadmittedInitialPct,100);
});
mathTest('a NAV catch-up and debt accrual reconcile with fees, carry and funded crypto',()=>{
  const rows=[row(0),row(86400,{prices:[2000,80000,1.01,1],debt:1.00012}),
    row(172800,{prices:[2100,78000,1.012,1],debt:1.00024,income:1.0001})];
  for(const asset of ['ETH','BTC']) {
    const r=simulate(rows,math,asset,{thresholdBps:1,tailBps:25},'perfect');
    assert.ok(r.income>50);assert.ok(r.interest>0);assert.ok(r.maxAccountingError<1e-5);
    assert.ok(r.fundedCryptoReturnPct>=0);assert.ok(r.protocolFeesUsd>0);
  }
});
mathTest('a source gap that breaches liquidation HF is flagged, never ranked as safe',()=>{
  const rows=[row(0),row(86400,{prices:[2000,80000,1.02,1]}),row(172800,{prices:[2000,80000,.1,1]})];
  const r=simulate(rows,math,'ETH',{sourceLimitBps:98,sourceReserveBps:100},'perfect');
  assert.equal(r.liquidatable,true);assert.ok(r.backingDeficitUsd>0);
  assert.ok(r.fundedCryptoReturnPct>=0);assert.ok(r.maxAccountingError<1e-5);
});
test('missing or mismatched archive observations fail rather than being interpolated',()=>{
  const p=point(0),h={start:0,end:1,snapshots:[{points:[p]}],markets:[]};
  assert.throws(()=>prepare(h,math),/missing exact/);
  h.markets=[{block:p.block,substrateHash:'wrong',t:0}];assert.throws(()=>prepare(h,math));
});
test('regime selection cannot see held-out candles',()=>{
  const candles=[];for(let d=0;d<90;d++)for(let hour=0;hour<24;hour++) {
    const p=100+4*Math.sin(d);candles.push({intervalStart:d*86400+hour*3600,open:p,close:p+.1});
  }
  const h={start:0,end:90*86400,candles:{ETH:structuredClone(candles),BTC:structuredClone(candles)}};
  const before=regimeWindows(h,60*86400);
  for(const a of ['ETH','BTC'])for(const c of h.candles[a])if(c.intervalStart>=60*86400)c.close=1e9;
  assert.deepEqual(regimeWindows(h,60*86400),before);
});
test('less admission or smaller deficits alone cannot win the funded-return objective',()=>{
  const prior={policy:{size:8000,sourceLimitBps:8},score:-.1,meanFundedPct:0};
  const idle={policy:{size:100,sourceLimitBps:98},score:-.001,meanFundedPct:0};
  assert.equal(selectPolicy([idle],prior).identifiedImprovement,false);
  assert.equal(selectPolicy([idle],prior).winner,prior);
  const better={policy:{size:1000,sourceLimitBps:8},score:.1,meanFundedPct:.1};
  assert.equal(selectPolicy([idle,better],prior).winner,better);
});
