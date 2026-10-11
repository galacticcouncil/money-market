// Re-score the archived operations campaign for operator-funded gas, and compare
// source-route trade slicing with the same pinned official pool math. No new
// annual contract simulations or future liquidity assumptions are implied.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {score, parseMetrics} from './tune-operations.mjs';
import {loadMath, poolQuote} from './pressure-model.mjs';

const [directory, output, monthlyArg = '10'] = process.argv.slice(2);
assert.ok(directory && output, 'usage: analyze-sponsored-swaps.mjs archived-campaign output.json [shared-monthly-usd]');
const monthlyBudgetUsd = Number(monthlyArg);
assert.ok(Number.isFinite(monthlyBudgetUsd) && monthlyBudgetUsd >= 0);
const read = name => JSON.parse(readFileSync(resolve(directory, name)));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const rounds = [1, 2, 3].map(i => read(`round-${i}.json`));
const market = read('market.json');
const costs = {...rounds[0].costs, sharedMonthlyUsd: [monthlyBudgetUsd]};
const ranking = [];
for (const round of rounds) {
  const groups = new Map();
  for (const r of round.rows) {
    const log = readFileSync(resolve(directory, `${r.id}.log`));
    assert.equal(sha(log), r.logSha256);
    assert.deepEqual(parseMetrics(log.toString()), r.metrics);
    if (!groups.has(r.candidate)) groups.set(r.candidate, []);
    groups.get(r.candidate).push(r);
  }
  const candidates = [...groups].map(([candidate, rows]) => {
    assert.equal(rows.length, 2);
    assert.equal(new Set(rows.map(r => r.config.ASSET)).size, 2);
    assert.ok(rows.every(r => r.metrics.backingDeficitUsd < 1e-5 && r.metrics.minimumHf >= 1
      && r.metrics.unadmittedUsd < r.config.TVL * 0.002
      && r.config.DISCOUNT_BPS === 0 && r.config.FEE_BPS === 500));
    return {round: round.round, candidate,
      meanUserReturnPct: rows.reduce((s, r) => s + r.score.fundedReturnPct, 0) / 2,
      cases: rows.map(r => {
        const current = score(r.metrics, r.config, costs);
        const standalone = current.allIn.find(x => x.sharedTvl === r.config.TVL);
        // In these flat-price optimization runs there are no source repayments.
        // Entry uses a constant all-in fill haircut; the remaining reconciled
        // trading loss is the crypto/servicing routes plus integer rounding.
        assert.equal(r.metrics.repays, 0);
        const estimatedEntryLossUsd = r.metrics.entryVolumeUsd * r.config.ENTRY_BPS / 10000;
        return {id: r.id, asset: r.config.ASSET === 0 ? 'ETH' : 'BTC', tvlUsd: r.config.TVL,
          userReturnPct: current.fundedReturnPct, fundedCryptoUsd: r.metrics.fundedCryptoUsd,
          unconvertedUserUsd: r.metrics.unconvertedUserUsd,
          tradingLossUsd: r.metrics.executionAndMarkLossUsd, estimatedEntryLossUsd,
          remainingTradingLossUsd: r.metrics.executionAndMarkLossUsd - estimatedEntryLossUsd,
          externalCostsUsd: current.directOperationsUsd + standalone.infrastructureUsd + standalone.sharedOnchainUsd,
          monthlyBudgetUsd, strategyReturnAfterExternalCostsPct: standalone.netFundedReturnPct,
          harvests: r.metrics.harvests, gasGateSkips: r.metrics.economicSkips,
          firstCryptoDay: r.metrics.firstCryptoHour / 24};
      })};
  }).sort((a, b) => b.meanUserReturnPct - a.meanUserReturnPct);
  ranking.push({round: round.round, originalWinner: round.winner.candidate, candidates});
}
const bestPreviouslyTested = ranking.flatMap(r => r.candidates).sort((a, b) => b.meanUserReturnPct - a.meanUserReturnPct)[0];
const math = loadMath(process.env.HYDRATION_MATH_ROOT);
const original = market.pools[143], price8 = BigInt(market.markets.PRIME.price);
const slices = [];
for (const totalUsd of [8000, 10000, 40000]) for (const chunkUsd of [100, 1000, 2500, totalUsd]) {
  for (const refill of [false, true]) {
    let pool = structuredClone(original), remaining = BigInt(totalUsd) * 10n ** 18n, outputPrime = 0n, calls = 0;
    let maximumSliceLossBps = -Infinity;
    while (remaining > 0n) {
      const amount = remaining < BigInt(chunkUsd) * 10n ** 18n ? remaining : BigInt(chunkUsd) * 10n ** 18n;
      const received = poolQuote(math.stable, pool, 222, 43, amount);
      const outputUsd = Number(received * price8) / 1e14;
      const inputUsd = Number(amount) / 1e18;
      maximumSliceLossBps = Math.max(maximumSliceLossBps, (1 - outputUsd / inputUsd) * 10000);
      outputPrime += received; remaining -= amount; calls++;
      if (!refill) {
        const h = pool.reserves.find(r => r.id === 222), p = pool.reserves.find(r => r.id === 43);
        h.balance = (BigInt(h.balance) + amount).toString();
        p.balance = (BigInt(p.balance) - received).toString();
      }
    }
    const lossUsd = totalUsd - Number(outputPrime * price8) / 1e14;
    slices.push({totalUsd, chunkUsd, calls, refillBetweenSlices: refill, lossUsd,
      averageLossBps: lossUsd / totalUsd * 10000, maximumSliceLossBps,
      withinTenBpWithTwoBpMargin: maximumSliceLossBps + 2 <= 10});
  }
}
const tiny = poolQuote(math.stable, original, 222, 43, 100n * 10n ** 18n);
const noFeePool = structuredClone(original); noFeePool.info.fee = 0;
const tinyNoFee = poolQuote(math.stable, noFeePool, 222, 43, 100n * 10n ** 18n);
const result = {
  objective: 'User funded crypto after debt, protocol fees and trading losses; operator-funded gas and the shared monthly infrastructure budget are tracked separately.',
  monthlyBudgetUsd, block: market.block, ranking, bestPreviouslyTested,
  sourcePool: {poolId: 143, feePpm: original.info.fee, nominalFeeBps: original.info.fee / 100,
    hundredDollarOutputWithFeeUsd: Number(tiny * price8) / 1e14,
    hundredDollarOutputWithoutFeeUsd: Number(tinyNoFee * price8) / 1e14},
  slices, dependencies: math.dependencies,
  inputs: Object.fromEntries(['market.json', ...[1, 2, 3].map(i => `round-${i}.json`)].map(f => [f, sha(readFileSync(resolve(directory, f)))])),
  limitations: [
    'Existing annual scenarios retain their original gas-batching policy. Re-ranking them does not simulate disabling that policy or rerun three sequential gas-sponsored optimization rounds.',
    'The first-round winner changes when gas is excluded; subsequent archived rounds inherited the original cost-weighted winner. Their best result is only the best already tested, not a new sponsored-gas optimum.',
    'Annual source entry/exit and crypto/servicing fills are fixed all-in loss assumptions; they cannot separately identify fees, price impact and quote-to-inclusion slippage.',
    'The slicing comparison uses official source-pool math at a pinned state. Sequential trades update reserves and retain fees; ideal refill restores the original pool between every slice and is conditional on outside trading/liquidity.',
    'Pool-math quotes exclude concurrent trading, time-varying pegs/oracles and native circuit breakers. They do not establish future execution or multi-vault throughput.',
    'The operator-funded budget is not a new deduction from user collateral; strategy net-of-all-costs figures remain a separate accounting sensitivity.',
  ],
};
writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify({monthlyBudgetUsd, sourcePool: result.sourcePool,
  roundWinnersWithoutGas: ranking.map(r => ({round: r.round, original: r.originalWinner, rescored: r.candidates[0].candidate})),
  bestPreviouslyTested, slices: slices.filter(r => r.totalUsd === 8000)}, null, 2));
