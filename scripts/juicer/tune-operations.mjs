// Three sequential rounds on actual Juicer accounting + execution controls.
// Market accrual/routes are mocked; native gas envelopes are explicit assumptions.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {resolve, dirname} from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const exec = promisify(execFile);
const sha = x => createHash('sha256').update(x).digest('hex');
const save = (path, x) => writeFileSync(path, JSON.stringify(x, null, 2) + '\n');

// Gas ALLOWANCES (already include estimation headroom), not receipt predictions.
// Deposit and harvest: native-controls.json, 3 Oct; harvest charged entirely to
// one vault, despite its measured two-vault batch. Remaining paths are provisional
// rounded bounds: do not present them as native measurements. Stress these 5x.
export const GAS = Object.freeze({
  deposit: 4_109_528, harvest: 8_193_855, serviceExtra: 3_000_000,
  borrow: 4_000_000, rebalance: 4_500_000, repay: 2_000_000,
  peg: 800_000, settlement: 1_400_000, safetySchedule: 300_000,
  approval: 150_000, claim: 1_000_000, policyRenewal: 1_000_000,
  deployment: 100_000_000,
});

export function inputRates(market, por, stepHours = 1) {
  assert.ok(stepHours > 0 && 24 % stepHours === 0);
  const prime = por.demo_prime_card.tokens.find(x => x.token === 'prime');
  assert.ok(prime, 'PRIME-specific net APY required');
  const primeApy = Number(prime.effective_rate) / 100;
  const supplyApr = Number(market.markets.PRIME.reserve.currentLiquidityRate) / 1e27;
  const borrowApr = Number(market.markets.HOLLAR.reserve.currentVariableBorrowRate) / 1e27;
  assert.ok(primeApy >= 0 && primeApy < 1 && supplyApr >= 0 && borrowApr >= 0);
  const steps = 365 * 24 / stepHours;
  return {primeApy, supplyApr, borrowApr,
    modeledYieldApr: steps * Math.expm1(Math.log1p(primeApy) / steps) + supplyApr};
}

export function parseMetrics(log) {
  assert.match(log, /\[PASS\] test_operationsTuning/);
  const m = {};
  for (const [, k, v] of log.matchAll(/^\s+([A-Za-z]+): (\d+)\s*$/gm)) {
    m[k] = k.endsWith('Usd') || k === 'minimumHf' ? Number(v) / 1e18 : Number(v);
  }
  for (const k of ['fundedCryptoUsd', 'unconvertedUserUsd', 'unconvertedProtocolUsd',
    'backingDeficitUsd', 'admittedUsd', 'unadmittedUsd', 'minimumHf', 'harvests',
    'servicingHarvests', 'deposits', 'borrows', 'rebalances', 'repays', 'settlements',
    'safetySchedules', 'pegUpdates', 'executionAndMarkLossUsd']) {
    assert.ok(Number.isFinite(m[k]) && m[k] >= 0, `missing/invalid ${k}`);
  }
  assert.ok(m.servicingHarvests <= m.harvests);
  return m;
}

export function costInputs(market, gas) {
  const gasPriceWei = Number(gas.gasPrice), ethPriceUsd = Number(market.markets.ETH.price) / 1e8;
  assert.ok(gasPriceWei > 0 && ethPriceUsd > 0);
  return {gasPriceWei, ethPriceUsd, feeQuoteMargin: 1.2,
    // Duty-slot redundancy still has a race/inclusion failure cost. Expected
    // 1% of productive keeper writes charged at the complete action allowance.
    failedWriteRate: 0.01, sharedMonthlyUsd: [0, 50, 200],
    deploymentGas: GAS.deployment, policyRenewalGasPerMonth: GAS.policyRenewal};
}

export function score(m, c, costs) {
  const years = c.DAYS / 365;
  assert.ok(c.TVL > 0 && years > 0);
  const nativeUsdPerGas = costs.gasPriceWei / 1e18 * costs.ethPriceUsd
    * costs.feeQuoteMargin * (c.GAS_MULTIPLIER ?? 1);
  const keeperGas = m.harvests * GAS.harvest + m.servicingHarvests * GAS.serviceExtra
    + m.borrows * GAS.borrow + m.rebalances * GAS.rebalance + m.repays * GAS.repay
    + m.pegUpdates * GAS.peg + m.settlements * GAS.settlement + m.safetySchedules * GAS.safetySchedule;
  const admissionGas = m.deposits * GAS.deposit + (m.deposits > 0 ? GAS.approval : 0);
  const failureGas = keeperGas * (c.FAILED_WRITE_RATE ?? costs.failedWriteRate);
  // One final carry-claim allowance; complete withdrawal/unwind remains separate.
  const claimGas = m.fundedCryptoUsd > 0 ? GAS.claim : 0;
  const recurringGas = keeperGas + failureGas;
  const totalGas = recurringGas + admissionGas + claimGas;
  const directOperationsUsd = totalGas * nativeUsdPerGas;
  const sharedPolicyUsd = costs.policyRenewalGasPerMonth * Math.ceil(12 * years) * nativeUsdPerGas;
  const deploymentUsd = costs.deploymentGas * nativeUsdPerGas;
  // External operating bills can exceed the position's principal. Preserve the
  // full one-year loss; a multi-year CAGR is undefined for negative end wealth.
  const annualize = value => years === 1 ? value / c.TVL * 100
    : value < -c.TVL ? null : (Math.pow(1 + value / c.TVL, 1 / years) - 1) * 100;
  const grossSource = m.sourceEquityUsd + m.loopDebtUsd;
  const illustrativeExitCostUsd = grossSource * c.EXIT_BPS / 10000;
  const exitCoverageGapUsd = Math.max(0, m.mainDebtUsd + illustrativeExitCostUsd - m.sourceEquityUsd - m.cashUsd);
  const netFundedUsd = m.fundedCryptoUsd - directOperationsUsd;
  return {nativeUsdPerGas, modeledNativeGas: totalGas, keeperGas, admissionGas, failureGas, claimGas,
    directOperationsUsd, keeperUsd: recurringGas * nativeUsdPerGas,
    admissionUsd: admissionGas * nativeUsdPerGas, claimUsd: claimGas * nativeUsdPerGas,
    sharedPolicyUsd, deploymentUsd, netFundedUsd,
    fundedReturnPct: annualize(m.fundedCryptoUsd), netFundedReturnPct: annualize(netFundedUsd),
    markedUserReturnPct: annualize(netFundedUsd + m.unconvertedUserUsd),
    fundingAdjustedReturnPct: annualize(netFundedUsd + m.unconvertedUserUsd - m.backingDeficitUsd),
    illustrativeExitCostUsd, exitCoverageGapUsd,
    indicativeClosedReturnPct: annualize(netFundedUsd + m.unconvertedUserUsd - m.backingDeficitUsd
      - illustrativeExitCostUsd),
    // Infrastructure is TOTAL for two operators and shared across deployment TVL;
    // these sensitivities are allocations, not proof of capacity at larger TVL.
    allIn: [c.TVL, 100_000, 1_000_000].filter((x, i, a) => x >= c.TVL && a.indexOf(x) === i).flatMap(sharedTvl =>
      costs.sharedMonthlyUsd.map(monthlyUsd => {
        const share = c.TVL / sharedTvl;
        const infrastructureUsd = monthlyUsd * 12 * years * share;
        const sharedOnchainUsd = (sharedPolicyUsd + deploymentUsd) * share;
        return {sharedTvl, monthlyUsd, infrastructureUsd, sharedOnchainUsd,
          netFundedReturnPct: annualize(netFundedUsd - infrastructureUsd - sharedOnchainUsd),
          holdingPeriodReturnPct: (netFundedUsd - infrastructureUsd - sharedOnchainUsd) / c.TVL * 100};
      })),
  };
}

export function select(rows) {
  const groups = new Map();
  for (const r of rows) { if (!groups.has(r.candidate)) groups.set(r.candidate, []); groups.get(r.candidate).push(r); }
  return [...groups].map(([candidate, cases]) => ({candidate, cases,
    meanReturnPct: cases.reduce((s, r) => s + r.score.netFundedReturnPct, 0) / cases.length,
    eligible: cases.length === 2 && new Set(cases.map(r => r.config.ASSET)).size === 2
      && cases.every(r => Number.isFinite(r.score.netFundedReturnPct)
        && r.metrics.backingDeficitUsd < 1e-5 && r.metrics.minimumHf >= 1
        && r.metrics.unadmittedUsd < r.config.TVL * 0.002
        && r.config.DISCOUNT_BPS === 0 && r.config.FEE_BPS === 500),
  })).filter(g => g.eligible).sort((a, b) => b.meanReturnPct - a.meanReturnPct)[0];
}

export function candidates(round) {
  if (round === 1) return [25, 1, 5, 10, 50].map(n => ({name: `threshold-${n}`, config: {THRESHOLD_BPS: n}}));
  if (round === 2) return [2500, 5000, 8000].flatMap(tranche => [250, 1000, 5000].map(daily => ({
    name: `trade-${tranche}-daily-${daily}`, config: {TRANCHE: tranche, ENTRY_DAILY: daily},
  })));
  // Round 1 found no economic skips at 25bp: source harvestability, not the
  // keeper's gas gate, is binding. Refine that threshold and optional buy pacing
  // instead of claiming gains from changing an inactive batching parameter.
  if (round === 3) return [25, 20, 30].flatMap(threshold => [1, 6, 24].map(every => ({
    name: threshold === 25 && every === 1 ? 'inherited' : `threshold-${threshold}-ramp-${every}h`,
    config: threshold === 25 && every === 1 ? {} : {THRESHOLD_BPS: threshold, BORROW_EVERY: every},
  })));
  assert.fail('round must be 1..3');
}

async function runCases(directory, prefix, choices, base, market, costs) {
  const rows = [], jobs = choices.flatMap(candidate => [0, 1].map(asset => ({candidate, asset})));
  let cursor = 0;
  const harnessHash = sha(readFileSync(resolve(root, 'juicer-vault/test/OperationsTuning.t.sol')));
  const run = async () => {
    while (cursor < jobs.length) {
      const {candidate, asset} = jobs[cursor++];
      const config = {...base, ...candidate.config, ASSET: asset, SWAP_BPS: asset === 0 ? 60 : 100,
        ASSET_PRICE: (BigInt(market.markets[asset === 0 ? 'ETH' : 'tBTC'].price) * 10n ** 10n).toString()};
      const pricePerGas = costs.gasPriceWei / 1e18 * costs.ethPriceUsd * costs.feeQuoteMargin * (config.GAS_MULTIPLIER ?? 1);
      config.HARVEST_GAS_USD = BigInt(Math.ceil(GAS.harvest * pricePerGas * 1e18)).toString();
      config.SERVICE_GAS_USD = BigInt(Math.ceil(GAS.serviceExtra * pricePerGas * 1e18)).toString();
      const id = `${prefix}-${candidate.name}-${asset === 0 ? 'ETH' : 'BTC'}`;
      const identity = sha(JSON.stringify({config, costs, harnessHash}));
      const caseFile = resolve(directory, `${id}.json`), logFile = resolve(directory, `${id}.log`);
      let row;
      if (existsSync(caseFile)) {
        row = JSON.parse(readFileSync(caseFile));
        assert.equal(row.identity, identity, `stale cached case ${id}`);
        assert.equal(row.logSha256, sha(readFileSync(logFile)), `changed log ${id}`);
        // Cache immutable contract results; always apply current presentation
        // and cost accounting, including explicit undefined multi-year CAGRs.
        row.score = score(row.metrics, config, costs);
        save(caseFile, row);
      } else {
        const env = {...process.env, RUN_OPERATIONS_TUNING: 'true', FOUNDRY_GAS_LIMIT: '1000000000000',
          ...Object.fromEntries(Object.entries(config).map(([k, v]) => [`OPS_${k}`, String(v)]))};
        const args = ['test', '--offline', '--evm-version', 'london', '--dynamic-test-linking',
          '--out', resolve(directory, 'out'), '--cache-path', resolve(directory, 'cache'),
          '--match-path', 'test/OperationsTuning.t.sol', '--match-test', 'test_operationsTuning', '-vv'];
        let log;
        try { const res = await exec('forge', args, {cwd: resolve(root, 'juicer-vault'), env,
          encoding: 'utf8', timeout: 600000, maxBuffer: 16 * 1024 * 1024}); log = res.stdout; }
        catch (e) { writeFileSync(logFile, String(e.stdout) + String(e.stderr)); throw e; }
        writeFileSync(logFile, log);
        const metrics = parseMetrics(log);
        row = {id, candidate: candidate.name, identity, config, metrics, score: score(metrics, config, costs), logSha256: sha(log)};
        save(caseFile, row);
      }
      rows.push(row);
      rows.sort((a, b) => a.id.localeCompare(b.id));
      save(resolve(directory, `${prefix}-partial.json`), rows);
      console.log(`${id}: ${row.score.netFundedReturnPct.toFixed(4)}% after $${row.score.directOperationsUsd.toFixed(2)} direct operations; first crypto day ${(row.metrics.firstCryptoHour / 24).toFixed(1)}; ${row.metrics.harvests} harvests; deficit $${row.metrics.backingDeficitUsd.toFixed(4)}`);
    }
  };
  const workers = Number(process.env.OPS_WORKERS ?? 4);
  assert.ok(Number.isSafeInteger(workers) && workers >= 1 && workers <= 4);
  await Promise.all(Array.from({length: workers}, run));
  return rows;
}

export async function runRound(directory, round) {
  mkdirSync(directory, {recursive: true});
  const read = f => JSON.parse(readFileSync(resolve(directory, f)));
  const market = read('market.json'), por = read('hastra-por.json'), gas = read('gas-price.json');
  // The Solidity fixture intentionally fixes these risk parameters/decimals.
  // Refuse a fresh market pin whose actual configuration no longer matches it.
  for (const [asset, decimals, ltv, lt] of [['ETH', 18, 7500, 8500], ['tBTC', 18, 8000, 8500], ['PRIME', 6, 8500, 8800]]) {
    assert.equal(market.markets[asset].decimals, decimals, `${asset} decimals changed`);
    assert.equal(market.markets[asset].ltvBps, ltv, `${asset} LTV changed`);
    assert.equal(market.markets[asset].ltBps, lt, `${asset} liquidation threshold changed`);
  }
  assert.equal(market.markets.HOLLAR.decimals, 18);
  assert.equal(market.markets.HOLLAR.price, '100000000', 'fixture values HOLLAR at par');
  const rates = inputRates(market, por), costs = costInputs(market, gas);
  const base = {TVL: 10_000, DAYS: 365, STEP_HOURS: 1,
    YIELD_RAY: BigInt(Math.round(rates.modeledYieldApr * 1e27)).toString(),
    BORROW_RAY: market.markets.HOLLAR.reserve.currentVariableBorrowRate,
    PRIME_PRICE: (BigInt(market.markets.PRIME.price) * 10n ** 10n).toString(),
    SOURCE_BPS: 10, THRESHOLD_BPS: 25, MIN_HARVEST: 1, BORROW_EVERY: 1,
    TRANCHE: 5000, ENTRY_BURST: 8000, ENTRY_DAILY: 1000,
    HARVEST_MAXIMUM: 200, HARVEST_DAILY: 1000, GAS_BPS: 10, MAX_DELAY_HOURS: 24,
    URGENT_INTEREST: 10, ENTRY_BPS: 5, EXIT_BPS: 7, DISCOUNT_BPS: 0, FEE_BPS: 500, STRESS: 0};
  let previous;
  if (round > 1) {
    previous = read(`round-${round - 1}.json`);
    assert.ok(previous.winner, 'finish previous round first');
    Object.assign(base, previous.winner.config);
  }
  const rows = await runCases(directory, `r${round}`, candidates(round), base, market, costs);
  const selected = select(rows);
  assert.ok(selected, 'no solvent, fully admitted ETH/BTC candidate; inspect failures');
  const config = {...selected.cases[0].config};
  for (const key of ['ASSET', 'ASSET_PRICE', 'SWAP_BPS', 'HARVEST_GAS_USD', 'SERVICE_GAS_USD']) delete config[key];
  const winner = {candidate: selected.candidate, meanReturnPct: selected.meanReturnPct, config};
  const result = {round, rates, costs, gasAllowances: GAS, block: market.block,
    previousWinner: previous?.winner, winner, rows,
    scope: 'Flat crypto prices; real contracts and controls; mocked market/routes. Direct operation costs included; shared infrastructure, deployment and complete exit shown separately. Positive liquidity refill is conditional, not funded by this model.',
    inputs: Object.fromEntries(['market.json', 'hastra-por.json', 'gas-price.json', 'routes.json'].map(f => [f, sha(readFileSync(resolve(directory, f)))]))};
  save(resolve(directory, `round-${round}.json`), result);
  console.log('ROUND WINNER', JSON.stringify(winner));
  return result;
}

export async function runHoldouts(directory) {
  const read = f => JSON.parse(readFileSync(resolve(directory, f)));
  const selected = read('round-3.json'), market = read('market.json');
  const choices = [
    {name: 'small-vault', config: {TVL: 1000}},
    {name: 'large-vault', config: {TVL: 100000}},
    {name: 'two-years', config: {DAYS: 730}},
    {name: 'gas-5x', config: {GAS_MULTIPLIER: 5}},
    {name: 'no-refill', config: {ENTRY_DAILY: 0}},
    {name: 'worse-fills', config: {ENTRY_BPS: 7, EXIT_BPS: 9}},
    {name: 'negative-spread', config: {STRESS: 1}},
    {name: 'outage-14d', config: {STRESS: 2}},
    {name: 'prime-gap-3pct', config: {STRESS: 3}},
  ];
  const rows = await runCases(directory, 'holdout', choices, selected.winner.config, market, selected.costs);
  const result = {selectedWinner: selected.winner, rows};
  save(resolve(directory, 'holdouts.json'), result);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  assert.ok(process.argv[2] && process.argv[3], 'usage: tune-operations.mjs evidence-directory 1|2|3|holdouts');
  const dir = resolve(process.argv[2]);
  if (process.argv[3] === 'holdouts') await runHoldouts(dir);
  else await runRound(dir, Number(process.argv[3]));
}
