import test from 'node:test';
import assert from 'node:assert/strict';
import {GAS, inputRates, parseMetrics, score, select, candidates} from './tune-operations.mjs';

const config = {TVL: 10000, DAYS: 365, EXIT_BPS: 7, FEE_BPS: 500, DISCOUNT_BPS: 0};
const costs = {gasPriceWei: 5e6, ethPriceUsd: 2700, feeQuoteMargin: 1.2,
  failedWriteRate: 0.01, sharedMonthlyUsd: [0, 50, 200], deploymentGas: 100e6,
  policyRenewalGasPerMonth: 1e6};
const metrics = {fundedCryptoUsd: 400, unconvertedUserUsd: 50, unconvertedProtocolUsd: 3,
  sourceEquityUsd: 7600, loopDebtUsd: 39000, mainDebtUsd: 7500, cashUsd: 0,
  backingDeficitUsd: 0, admittedUsd: 10000, unadmittedUsd: 0, minimumHf: 1.05,
  harvests: 0, servicingHarvests: 0, borrows: 0, rebalances: 0, repays: 0,
  settlements: 0, safetySchedules: 0, pegUpdates: 0, deposits: 0, executionAndMarkLossUsd: 50};

test('hourly accrual reconstructs Hastra net APY without double-counting fees', () => {
  const rates = inputRates({markets: {PRIME: {reserve: {currentLiquidityRate: '0'}},
    HOLLAR: {reserve: {currentVariableBorrowRate: '40000000000000000000000000'}}}},
  {demo_prime_card: {fee: '0.5', tokens: [{token: 'auto', effective_rate: '99'},
    {token: 'prime', effective_rate: '5.6159'}]}});
  assert.ok(Math.abs((1 + rates.modeledYieldApr / 8760) ** 8760 - 1 - 0.056159) < 1e-11);
  assert.equal(rates.borrowApr, 0.04);
});

test('zero-work safety observations cost RPC overhead, not invented chain fees', () => {
  const r = score(metrics, config, costs);
  assert.equal(r.keeperGas, 0);
  assert.equal(r.admissionGas, 0);
  assert.equal(r.modeledNativeGas, GAS.claim);
  assert.ok(r.allIn.find(x => x.monthlyUsd === 50).infrastructureUsd > 0);
});

test('counts controlled deposits, service legs, useful settlement and failed writes', () => {
  const m = {...metrics, deposits: 2, harvests: 3, servicingHarvests: 2, settlements: 4};
  const r = score(m, config, costs);
  assert.equal(r.keeperGas, 3 * GAS.harvest + 2 * GAS.serviceExtra + 4 * GAS.settlement);
  assert.equal(r.admissionGas, 2 * GAS.deposit + GAS.approval);
  assert.equal(r.failureGas, r.keeperGas / 100);
  assert.equal(score(m, {...config, GAS_MULTIPLIER: 5}, costs).directOperationsUsd, r.directOperationsUsd * 5);
});

test('shared operators and deployment are allocated once by aggregate TVL', () => {
  const r = score(metrics, config, costs);
  const local = r.allIn.find(x => x.sharedTvl === 10000 && x.monthlyUsd === 50);
  const shared = r.allIn.find(x => x.sharedTvl === 100000 && x.monthlyUsd === 50);
  assert.equal(local.infrastructureUsd, 600);
  assert.equal(shared.infrastructureUsd, 60);
  assert.equal(shared.sharedOnchainUsd, local.sharedOnchainUsd / 10);
  assert.ok(local.netFundedReturnPct < shared.netFundedReturnPct);
});

test('external bills larger than principal are visible; negative multi-year wealth has no CAGR', () => {
  const small = {...config, TVL: 1000};
  const loss = score(metrics, small, costs).allIn.find(x => x.sharedTvl === 1000 && x.monthlyUsd === 200);
  assert.ok(loss.netFundedReturnPct < -100);
  const longer = score(metrics, {...small, DAYS: 730}, costs).allIn.find(x => x.sharedTvl === 1000 && x.monthlyUsd === 200);
  assert.equal(longer.netFundedReturnPct, null);
  assert.ok(longer.holdingPeriodReturnPct < -100);
});

test('funded crypto, user carry, protocol carry, insolvency and closing costs stay distinct', () => {
  const r = score(metrics, config, costs);
  assert.ok(r.markedUserReturnPct > r.netFundedReturnPct);
  const protocol = score({...metrics, unconvertedProtocolUsd: 10000}, config, costs);
  assert.equal(protocol.markedUserReturnPct, r.markedUserReturnPct);
  const impaired = score({...metrics, backingDeficitUsd: 100}, config, costs);
  assert.ok(impaired.fundingAdjustedReturnPct < r.fundingAdjustedReturnPct);
  assert.ok(r.indicativeClosedReturnPct < r.markedUserReturnPct);
});

test('cannot win on missing/duplicate asset, subsidy, missing admission or loss', () => {
  const pair = (name, pct, changes = {}, overrides = {}) => [0, 1].map(ASSET => ({candidate: name,
    metrics: {...metrics, ...changes}, config: {...config, ASSET, ...overrides},
    score: {netFundedReturnPct: pct}}));
  assert.equal(select([...pair('safe', 3), ...pair('bad', 10, {backingDeficitUsd: 1}),
    ...pair('missing-admission', 10, {unadmittedUsd: 100}), ...pair('subsidy', 10, {}, {DISCOUNT_BPS: 5000}),
    ...pair('duplicate', 10, {}, {ASSET: 0}), pair('missing', 10)[0]]).candidate, 'safe');
});

test('parser rejects incomplete, failed and impossible service counts', () => {
  const log = m => '[PASS] test_operationsTuning()\n' + Object.entries(m).map(([k, v]) =>
    `  ${k}: ${BigInt(Math.round(v * (k.endsWith('Usd') || k === 'minimumHf' ? 1e18 : 1)))}`).join('\n');
  assert.equal(parseMetrics(log(metrics)).fundedCryptoUsd, 400);
  assert.throws(() => parseMetrics('[FAIL] test_operationsTuning()'));
  assert.throws(() => parseMetrics('[PASS] test_operationsTuning()'));
  assert.throws(() => parseMetrics(log({...metrics, servicingHarvests: 1})));
});

test('each round retains the preceding baseline to expose non-improvements', () => {
  assert.ok(candidates(1).some(x => x.config.THRESHOLD_BPS === 25));
  assert.ok(candidates(2).some(x => x.config.TRANCHE === 5000 && x.config.ENTRY_DAILY === 1000));
  assert.deepEqual(candidates(3).find(x => x.name === 'inherited').config, {});
});
