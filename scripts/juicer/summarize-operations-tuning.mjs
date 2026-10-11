import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import {score, select, GAS} from './tune-operations.mjs';

const directory = resolve(process.argv[2]);
const read = file => JSON.parse(readFileSync(resolve(directory, file)));
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const rounds = [1, 2, 3].map(i => read(`round-${i}.json`));
for (let i = 1; i < rounds.length; i++) {
  assert.deepEqual(rounds[i].previousWinner, rounds[i - 1].winner, 'each round must inherit the preceding winner');
  assert.deepEqual(rounds[i].inputs, rounds[0].inputs, 'inputs must be held constant across optimization rounds');
}
for (const round of rounds) {
  assert.equal(select(round.rows).candidate, round.winner.candidate);
  for (const row of round.rows) {
    assert.equal(row.logSha256, sha(readFileSync(resolve(directory, `${row.id}.log`))));
    assert.ok(Math.abs(score(row.metrics, row.config, round.costs).netFundedReturnPct - row.score.netFundedReturnPct) < 1e-10);
  }
}
const holdouts = read('holdouts.json');
assert.deepEqual(holdouts.selectedWinner, rounds[2].winner);
const rows = [...rounds.flatMap(r => r.rows), ...holdouts.rows];
const fields = ['id', 'asset', 'tvlUsd', 'days', 'thresholdBps', 'trancheHollar', 'entryDailyHollar',
  'borrowEveryHours', 'fundedCryptoUsd', 'unconvertedUserUsd', 'unconvertedProtocolUsd',
  'directOperationsUsd', 'netFundedReturnPct', 'executionAndMarkLossUsd', 'protocolFeeUsd',
  'mainInterestUsd', 'loopInterestUsd', 'firstCryptoDay', 'admissionCompleteDay', 'unadmittedUsd',
  'harvests', 'borrows', 'rebalances', 'servicingHarvests', 'settlements',
  'economicSkips', 'quoteSkips', 'backingDeficitUsd', 'exitCoverageGapUsd', 'minimumHf'];
const csv = rows.map(r => [r.id, r.config.ASSET === 0 ? 'ETH' : 'BTC', r.config.TVL, r.config.DAYS,
  r.config.THRESHOLD_BPS, r.config.TRANCHE, r.config.ENTRY_DAILY, r.config.BORROW_EVERY,
  r.metrics.fundedCryptoUsd, r.metrics.unconvertedUserUsd, r.metrics.unconvertedProtocolUsd,
  r.score.directOperationsUsd, r.score.netFundedReturnPct, r.metrics.executionAndMarkLossUsd,
  r.metrics.protocolFeeUsd, r.metrics.mainInterestUsd, r.metrics.loopInterestUsd,
  r.metrics.firstCryptoHour / 24, r.metrics.admissionCompleteHour / 24, r.metrics.unadmittedUsd,
  r.metrics.harvests, r.metrics.borrows, r.metrics.rebalances, r.metrics.servicingHarvests,
  r.metrics.settlements, r.metrics.economicSkips, r.metrics.quoteSkips,
  r.metrics.backingDeficitUsd, r.score.exitCoverageGapUsd, r.metrics.minimumHf]);
writeFileSync(resolve(directory, 'comparison.csv'), [fields, ...csv].map(x => x.join(',')).join('\n') + '\n');
const selected = rounds[2].rows.filter(r => r.candidate === rounds[2].winner.candidate);
const summary = {
  cases: rows.length, simulatedDays: rows.reduce((n, r) => n + r.config.DAYS, 0),
  rates: rounds[0].rates, costs: rounds[0].costs, gasAllowances: GAS,
  rounds: rounds.map(r => ({round: r.round, winner: r.winner,
    selected: r.rows.filter(row => row.candidate === r.winner.candidate)})),
  selected, holdouts,
  illustrativeTerminalCosts: selected.map(r => {
    // A cost sensitivity, not an executed redemption or source-liquidity proof.
    // Allow one request, enough bounded full-source sale steps, settlement and
    // collateral claim. The underlying close path must be rehearsed separately.
    const fullSource = r.metrics.sourceEquityUsd + r.metrics.loopDebtUsd;
    const steps = Math.ceil(fullSource / r.config.TRANCHE);
    const gas = 3_000_000 + steps * 3_000_000 + GAS.settlement + GAS.claim;
    return {asset: r.config.ASSET, sourceSaleSteps: steps, gasAllowance: gas,
      gasUsd: gas * r.score.nativeUsdPerGas, sourceTradingUsd: r.score.illustrativeExitCostUsd,
      scope: 'Additional indicative terminal cost; not included in funded-return headline. No executed exit or redemption-time guarantee.'};
  }),
  limitations: [
    'No production parameter or mainnet transaction changed.',
    'Real accounting/controller contracts with mocked market accrual and fixed-fee routes; no donated income or funded recovery in the economic runs.',
    'Flat crypto prices. Hourly modeling is coarser than 30-second production safety monitoring; it does not establish safety response latency.',
    'This is an hourly policy simulation, not a replay of the production keeper: it allows up to eight sequential ramp calls per observation. Production polls faster and submits one ramp per cycle; validate cadence-dependent gas and quote traffic before using these as a budget.',
    'PRIME net effective APY is backward-looking, includes Hastra fees and wYLDS; Aave PRIME supply APR is additional. Direct crypto Aave supply income is excluded.',
    'Positive admission refill assumes external replenishment at the modeled fill price. A token bucket cannot replenish pool inventory; operator quote checks still apply.',
    'ETH and BTC scenarios are isolated alternatives sharing no simultaneous liquidity. Deployment-TVL overhead allocations are arithmetic sensitivities, not scaling guarantees.',
    'Trading losses are already charged through execution. executionAndMarkLossUsd includes the NAV shock in that stress case, and must not be charged twice.',
    'Native deposit and harvest receipt anchors are state-specific. Main-service and other action gas allowances are provisional; 5x gas-price stress changes both costs and keeper decisions, not the native gas ceiling.',
    'Read-only preview/safety calls do not pay chain gas; their RPC/hosting/operator costs are represented by explicit total shared monthly budgets. Zero budget means sponsored operations.',
    '1% failed-write allowance and gas margins are assumptions. Instant quoted fills exclude market movement and competition; actual failures can be more expensive.',
    'Funded yield is actual collateral earned, not unconverted yield. Unconverted protocol carry is excluded from user return.',
    'Costs are external USD-equivalent burdens subtracted at the horizon, not implemented deductions from collateral or simulated periodic capital withdrawals.',
    'Shared deployment and policy renewal costs are separate. Final withdrawal gas/trading estimates are illustrative only; liquidation losses, replenisher fees and audit costs have no measured budget here.',
    'A positive funded return can coexist with an unpaid Main backing deficit in stress; deficit-adjusted values and frozen admission remain visible.',
  ],
};
writeFileSync(resolve(directory, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({cases: summary.cases, simulatedDays: summary.simulatedDays,
  rounds: summary.rounds.map(r => ({round: r.round, candidate: r.winner.candidate,
    meanReturnPct: r.winner.meanReturnPct})), terminal: summary.illustrativeTerminalCosts}, null, 2));
