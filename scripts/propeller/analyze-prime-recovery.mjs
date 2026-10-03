// Historical inventory-recovery reference, not a causal arbitrage detector or
// annual APY simulation. Perfect refill is an explicit same-price benchmark.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {loadMath, poolQuote} from './pressure-model.mjs';
import {quantile, timestamp} from './neckwork-calibration.mjs';

const WAD = 10n ** 18n;
export function summary(values) {
  return {count: values.length, min: values.length ? Math.min(...values) : null,
    median: quantile(values, .5), p90: quantile(values, .9),
    max: values.length ? Math.max(...values) : null,
    mean: values.length ? values.reduce((a, b) => a + b, 0) / values.length : null};
}

// Each start is a separate hypothetical order. Both sides of the observed NET
// inventory must replace our cumulative consumption; opposing buyers are thus
// included. No capacity is manufactured on a timer or reused within an order.
// Stop at issuance changes: LP inflows are not counted as trading recovery.
export function recoverySchedule(points, start, amountHollar, chunkHollar, primePerSlice) {
  assert.ok(amountHollar > 0n && chunkHollar > 0n && amountHollar % chunkHollar === 0n);
  assert.ok(primePerSlice > 0n);
  const first = points[start], count = Number(amountHollar / chunkHollar);
  let filled = 1, capitalHours = 0, finishHours = 0, endReason = 'window-ended';
  for (let j = start + 1; j < points.length && filled < count; j++) {
    const p = points[j];
    if (p.issuance !== first.issuance) { endReason = 'issuance-changed'; break; }
    if (p.t - points[j - 1].t > 3600) { endReason = 'observation-gap'; break; }
    const pGrowth = BigInt(p.reserves[0]) - BigInt(first.reserves[0]);
    const hRemoved = BigInt(first.reserves[1]) - BigInt(p.reserves[1]);
    const hours = (p.t - first.t) / 3600;
    while (filled < count && pGrowth >= BigInt(filled) * primePerSlice
      && hRemoved >= BigInt(filled) * chunkHollar) {
      capitalHours += Number(chunkHollar) / 1e18 * hours;
      finishHours = hours; filled++;
    }
  }
  return {complete: filled === count, filledSlices: filled, totalSlices: count,
    completionHours: filled === count ? finishHours : null,
    capitalHours: filled === count ? capitalHours : null,
    endReason: filled === count ? 'filled' : endReason};
}

export function analyze(history, market, math) {
  const points = history.snapshots.flatMap(s => {
    assert.deepEqual(s.assets.map(a => a.assetId), [43, 222]);
    assert.equal(s.coverage.missingCount, 0); assert.equal(s.coverage.truncated, false);
    return s.points;
  }).sort((a, b) => a.block - b.block);
  assert.equal(new Set(points.map(p => p.block)).size, points.length);
  for (let i = 1; i < points.length; i++) {
    assert.ok(points[i].block > points[i - 1].block && points[i].t > points[i - 1].t);
  }
  const completeDays = new Set(history.days.filter(d => d.exhausted).map(d => d.date));
  const rows = history.rows.filter(r => completeDays.has(r.timestamp.slice(0, 10))
    && ![r.assetIn, r.assetOut].includes(1043)
    && ((r.assetIn === 43) !== (r.assetOut === 43)) && r.amountIn && r.amountOut);
  const periods = [{name: 'before-dca', from: history.from, to: '2026-09-26'},
    {name: 'recent-dca', from: '2026-09-26', to: history.toExclusive}];
  const flow = periods.map(period => {
    const dates = [...completeDays].filter(d => d >= period.from && d < period.to);
    const subset = rows.filter(r => dates.includes(r.timestamp.slice(0, 10)));
    const sells = subset.filter(r => r.assetIn === 43), buys = subset.filter(r => r.assetOut === 43);
    const sum = a => a.reduce((n, r) => n + (r.valueUsd || 0), 0);
    const daily = dates.map(date => ({date,
      soldUsd: sum(sells.filter(r => r.timestamp.startsWith(date))),
      boughtUsd: sum(buys.filter(r => r.timestamp.startsWith(date)))}));
    const gaps = sells.slice(1).flatMap((r, i) => {
      // Include overnight gaps, but not a censored day between observations.
      const previous = sells[i], datesBetween = [];
      for (let t = Date.parse(previous.timestamp.slice(0, 10)); t <= Date.parse(r.timestamp.slice(0, 10)); t += 86400000)
        datesBetween.push(new Date(t).toISOString().slice(0, 10));
      return datesBetween.every(d => completeDays.has(d))
        ? [(timestamp(r.timestamp) - timestamp(previous.timestamp)) / 60] : [];
    });
    const treasury = sells.filter(r => r.tag === 'treasury');
    return {...period, completeDays: dates.length, classifiedActions: subset.length,
      sellCount: sells.length, buyCount: buys.length, soldUsd: sum(sells), boughtUsd: sum(buys),
      meanDailySoldUsd: sum(sells) / dates.length, meanDailyBoughtUsd: sum(buys) / dates.length,
      dailySalesUsd: summary(daily.map(d => d.soldUsd)), saleGapsMinutes: summary(gaps),
      treasurySellUsd: sum(treasury), treasuryShareOfSells: sum(treasury) / sum(sells), daily};
  });
  const quoteRows = points.map(p => {
    const pool = {info: {fee: p.feePermill, finalAmplification: p.amplification},
      reserves: [43, 222].map((id, i) => ({id, balance: p.reserves[i], info: {decimals: i ? 18 : 6}})),
      pegs: {current: p.pegs.map(v => [v.num, v.den])}};
    const price = Number(p.pegs[0].num) / Number(p.pegs[0].den);
    const quotes = {};
    for (const size of [100, 1000, 8000]) {
      const out = poolQuote(math.stable, pool, 222, 43, BigInt(size) * WAD);
      quotes[size] = (1 - Number(out) / 1e6 * price / size) * 10000;
    }
    return {block: p.block, time: p.time, price, quotes, issuance: p.issuance};
  });
  const quoteSummary = periods.map(period => {
    const ps = quoteRows.filter(p => p.time >= period.from && p.time < period.to);
    return {...period, points: ps.length, sizes: [100, 1000, 8000].map(size => {
      const losses = ps.map(p => p.quotes[size]);
      return {hollar: size, effectiveLossVsPoolPegBps: summary(losses),
        fractionWithin8Bp: losses.filter(x => x <= 8).length / losses.length};
    })};
  });
  const pool = market.pools[143], reference = BigInt(market.markets.PRIME.price);
  const scenarios = [];
  for (const total of [8000, 40000]) for (const chunk of [100, 1000, 8000]) {
    const out = poolQuote(math.stable, pool, 222, 43, BigInt(chunk) * WAD);
    const idealLossUsd = total - Number(out * reference) / 1e14 * total / chunk;
    let sequential = structuredClone(pool), received = 0n, worstImmediateSliceLossBps = -Infinity;
    for (let q = 0; q < total; q += chunk) {
      const o = poolQuote(math.stable, sequential, 222, 43, BigInt(chunk) * WAD);
      worstImmediateSliceLossBps = Math.max(worstImmediateSliceLossBps,
        (1 - Number(o * reference) / 1e14 / chunk) * 10000);
      const h = sequential.reserves.find(r => r.id === 222), p = sequential.reserves.find(r => r.id === 43);
      h.balance = (BigInt(h.balance) + BigInt(chunk) * WAD).toString();
      p.balance = (BigInt(p.balance) - o).toString(); received += o;
    }
    const immediateLossUsd = total - Number(received * reference) / 1e14;
    for (const period of periods) {
      const ps = points.filter(p => p.time >= period.from && p.time < period.to);
      const schedules = ps.map((_, start) => recoverySchedule(ps, start, BigInt(total) * WAD, BigInt(chunk) * WAD, out));
      const filled = schedules.filter(s => s.complete);
      const waiting = summary(filled.map(s => s.completionHours));
      const capitalHours = summary(filled.map(s => s.capitalHours));
      scenarios.push({period: period.name, totalHollar: total, chunkHollar: chunk,
        trials: schedules.length, completed: filled.length,
        censored: Object.fromEntries(['window-ended', 'issuance-changed', 'observation-gap'].map(reason =>
          [reason, schedules.filter(s => s.endReason === reason).length])),
        immediateSequentialLossUsd: immediateLossUsd,
        worstImmediateSliceLossBps, immediateEverySliceWithin8Bp: worstImmediateSliceLossBps <= 8,
        perfectRefill: {completionHours: 0, lossUsd: idealLossUsd},
        observedNetInventorySchedule: {completionHoursForCompleted: waiting,
          capitalHoursForCompleted: capitalHours,
          lossUsdIfSameQuoteRestored: idealLossUsd,
          medianDelayExpenseAtOnePctAnnualMarginalReturnUsd: capitalHours.median === null ? null : capitalHours.median / 8760 * .01,
          medianBreakEvenAnnualMarginalReturnPct: capitalHours.median > 0 ?
            (immediateLossUsd - idealLossUsd) / capitalHours.median * 8760 * 100 : null}});
    }
  }
  const issuanceChanges = points.slice(1).flatMap((p, i) => p.issuance === points[i].issuance ? []
    : [{fromBlock: points[i].block, toBlock: p.block, from: points[i].time, to: p.time}]);
  const dca = history.treasuryDca;
  assert.equal(dca.scheduleId, 37930);
  assert.ok(dca.route.some(r => r.poolId === 143 && r.assetIn.assetId === 43));
  const remaining = BigInt(dca.totalAmount) - BigInt(dca.executions.totalIn);
  const dcaBudget = {scheduleId: dca.scheduleId, status: dca.status,
    createdAt: dca.createdAt, latestExecution: dca.rows[0]?.timestamp,
    totalPrime: Number(dca.totalAmount) / 1e6,
    soldPrime: Number(dca.executions.totalIn) / 1e6,
    remainingPrimeBeforeFees: Number(remaining) / 1e6,
    fractionSold: Number(dca.executions.totalIn) / Number(dca.totalAmount),
    primePerTrade: Number(dca.amountPer) / 1e6, periodBlocks: dca.period,
    nominalHoursRemainingBeforeFees: Number(remaining) / Number(dca.amountPer) * dca.periodSeconds / 3600,
    caveat: 'Residual budget subtracts swap input only, not transaction fees. Nominal time assumes uninterrupted cadence and no top-up; this is a finite Treasury schedule, not permanent arbitrage capacity.'};
  return {window: {from: history.from, toExclusive: history.toExclusive},
    coverage: {reservePoints: points.length, maximumSamplingGapMinutes: Math.max(...points.slice(1).map((p, i) => (p.t - points[i].t) / 60)),
      activityDaysComplete: completeDays.size, activityDaysPartial: history.days.filter(d => !d.exhausted),
      activityRowsCollected: history.rows.length, issuanceChanges},
    source: history.api, mathDependencies: math.dependencies, dcaBudget, flow, quoteSummary, quoteRows, scenarios,
    latestSnapshot: points.at(-1),
    pinnedQuoteBlock: market.block,
    limitations: [
      'Historical endpoint sales and purchases are not all proven arbitrage; representative raw blocks confirm pool 143 and Treasury DCA, not all routes or external profits.',
      'Recent gross replenishment is dominated by finite Treasury DCA 37930. Its observed activity must not be repeated indefinitely in an annual model; pre-DCA and no-refill cases remain relevant.',
      'One capped activity day is excluded entirely from daily flow statistics. Exact reserve observations cover that day too; no missing interval is assumed empty.',
      'Pool-peg quote loss measures reserve imbalance, trade impact and fees against that point\'s stored peg. It is not loss against independent fair value or the vault oracle.',
      'Inventory schedules require both observed net PRIME increases and HOLLAR decreases, counting competing flow. They are independent historical start scenarios, not simultaneous orders or guaranteed future capacity.',
      'Schedules stop at LP issuance changes and observation gaps over one hour. Incomplete trials remain censored, not instantaneous fills; completed-only quantiles have survivor bias.',
      'The timing benchmark holds the original pinned execution quote constant and credits historical inventory quantities. Same-quote restoration and future repetitions are assumptions; it is not a replay of the historical prices or an endogenous arbitrage simulation.',
      'Perfect arbitrage resets the executable state before each slice with zero replenishment latency; normal pool fees and each slice\'s impact remain. External inventory/capital is assumed available.',
      'Delay expense is per 1% annual marginal return on the unexecuted HOLLAR amount, not a new APY estimate. Real carry depends on when Main/source debt is borrowed, yield accrual and compounding.',
      'The production oracle guard, fresh previews, native circuit breakers and risk limits still apply. Neither scenario configures a keeper or changes on-chain policy.',
    ]};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [historyFile, marketFile, output] = process.argv.slice(2);
  assert.ok(output, 'usage: analyze-prime-recovery.mjs history.json market.json output.json');
  const historyRaw = readFileSync(historyFile), marketRaw = readFileSync(marketFile);
  const result = analyze(JSON.parse(historyRaw), JSON.parse(marketRaw), loadMath(process.env.HYDRATION_MATH_ROOT));
  result.inputs = {historySha256: createHash('sha256').update(historyRaw).digest('hex'),
    marketSha256: createHash('sha256').update(marketRaw).digest('hex')};
  writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify({...result, quoteRows: undefined}, null, 2));
}
