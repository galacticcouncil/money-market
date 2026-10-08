import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { score } from './tune-mainnet.mjs';

const directory = resolve(process.argv[2]);
const read = name => JSON.parse(readFileSync(resolve(directory, name)));
const rounds = [1, 2, 3, 4, 5].map(i => read(`round-${i}.json`));
for (let i = 1; i < rounds.length; i++) {
  assert.deepEqual(rounds[i].previousWinner, rounds[i - 1].winner, 'rounds must feed the actual preceding winner');
}
const rows = rounds.flatMap(r => r.rows.map(row => ({ round: r.round, ...row })));
const routes = read('routes.json'), holdout = read('holdout-routes.json');
const native = read('maintenance-gas.json');
const market = read('market.json');
const winner = rounds[4].winner;
const selected = rounds[4].rows.filter(r => r.candidate === 'selected');
const quoteBudgets = [10, 25].map(bps => {
  const conservativeBudget = Math.min(...[routes, holdout].flatMap(r => r.sequential
    .filter(x => x.sourceBps === bps).map(x => x.noRefillCumulativeHollar)));
  const tvlAt80PctBudget = conservativeBudget * 0.8 / (routes.capacity.leverage * 0.8);
  return { sourceBps: bps, noRefillBudgetHollarAcrossBothPins: conservativeBudget,
    sharedTvlAt80PctBudgetWorstCollateralLtv: tvlAt80PctBudget,
    scope: 'Aggregate of all attached vaults, fixed-peg pool math only; no native circuit-breaker or replenishment guarantee.' };
});
const fields = ['round', 'id', 'asset', 'tvl', 'days', 'sourceBps', 'thresholdBps', 'harvestEveryDays',
  'minimumHarvestUsd', 'borrowEveryDays', 'trancheHollar', 'discountBps', 'feeBps',
  'fundedReturnPct', 'netFundedReturnPct', 'markedOwnedReturnPct', 'fundingAdjustedEconomicReturnPct', 'keeperUsd',
  'firstCryptoDay', 'harvests', 'borrows', 'backingDeficitUsd', 'exitCoverageGapUsd',
  'waivedInterestUsd', 'protocolFeeUsd', 'minimumHf'];
const csvRows = rows.map(r => [r.round, r.id, r.config.ASSET === 0 ? 'ETH' : 'BTC', r.config.TVL,
  r.config.DAYS, r.config.SOURCE_BPS, r.config.THRESHOLD_BPS, r.config.EVERY,
  r.config.MIN_HARVEST, r.config.BORROW_EVERY, r.config.TRANCHE, r.config.DISCOUNT_BPS, r.config.FEE_BPS,
  r.score.fundedReturnPct, r.score.netFundedReturnPct, r.score.markedOwnedReturnPct,
  r.score.fundingAdjustedEconomicReturnPct, r.score.keeperUsd,
  r.metrics.firstCryptoDay || '', r.metrics.harvests, r.metrics.borrows,
  r.metrics.backingDeficitUsd, r.score.exitCoverageGapUsd, r.metrics.waivedInterestUsd,
  r.metrics.protocolFeeUsd, r.metrics.minimumHf]);
writeFileSync(resolve(directory, 'comparison.csv'), [fields, ...csvRows].map(row => row.join(',')).join('\n') + '\n');
const summary = {
  block: market.block, hash: market.hash, holdoutBlock: holdout.block, holdoutHash: holdout.hash,
  rates: rounds[0].rates, cases: rows.length,
  simulatedDays: rows.reduce((sum, row) => sum + row.config.DAYS, 0),
  rounds: rounds.map(r => ({ round: r.round, winner: r.winner,
    cases: r.rows.length, selected: r.rows.filter(row => row.candidate === r.winner.candidate) })),
  candidateSettings: winner.config, quoteBudgets,
  gas5x: selected.map(r => ({ asset: r.config.ASSET,
    score: score(r.metrics, r.config, Number(market.markets.ETH.price) / 1e8, 5) })),
  maintenanceCadence: {
    nativeBlock: native.block,
    nativeMeasuredUpperBounds: native.rows.map(({ asset, functionName, executable, gasUpperBound }) =>
      ({ asset, functionName, executable, gasUpperBound })),
    modeledDailyBudgetGas: 3400000,
    fiveMinuteVsDailyFrequencyRatio: 288,
    fiveMinuteAnnualBudgetUsdPerVault: 365 * 288 * 3400000 * 5536035 / 1e18 *
      Number(market.markets.ETH.price) / 1e8 * 1.2,
    scope: 'Frequency-only budget sensitivity with fixed gas price and no receipt/poll latency; not measured annual spending. Actual keeper defaults to 30-second polling and slow work every 10 cycles. Daily modeled writes require new scheduling/gates; safety monitoring must remain frequent.',
  },
  limitations: [
    'No production parameters or on-chain transactions changed.',
    'Real Propeller contracts; mocked Aave and router boundaries with fixed crypto prices and interest paths.',
    'Source 5bp entry / 7bp exit and ETH 60bp / BTC 100bp swap costs are modeled assumptions calibrated to route evidence; external refill is not guaranteed.',
    'Each primary case is one isolated $10k vault, not simultaneous $10k ETH plus $10k BTC using independent liquidity.',
    'Funded return is increased crypto collateral; marked owned return includes unconverted yield and excludes terminal execution costs.',
    'Keeper gas is modeled operating cost, not currently debited from user shares; daily maintenance differs from current production keeper cadence.',
    'The illustrative exit coverage gap is accounting sensitivity, not an executed exit or redemption-liquidity guarantee.',
    'Discounts waive Main interest only; they are explicit foregone HOLLAR revenue, and source borrowing remains undiscounted.',
    'Fees, discounts and parameter recommendations still require governance configuration; size/cost gates need keeper work.',
  ],
};
writeFileSync(resolve(directory, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ cases: summary.cases, simulatedDays: summary.simulatedDays,
  quoteBudgets, fiveMinuteAnnualBudgetUsdPerVault: summary.maintenanceCadence.fiveMinuteAnnualBudgetUsdPerVault }, null, 2));
