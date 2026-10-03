import test from 'node:test';
import assert from 'node:assert/strict';
import { inputRates, parseMetrics, score, select } from './tune-mainnet.mjs';

test('uses PRIME-specific net APY, preserves daily compounding, adds only Aave income', () => {
  const rates = inputRates({ markets: {
    PRIME: { reserve: { currentLiquidityRate: '0' } },
    HOLLAR: { reserve: { currentVariableBorrowRate: '40000000000000000000000000' } },
  } }, { demo_prime_card: { effective_rate: '99', fee: '0.5', tokens: [
    { token: 'auto', effective_rate: '80' }, { token: 'prime', effective_rate: '5.6515' },
  ] } });
  assert.ok(Math.abs((1 + rates.modeledYieldApr / 365) ** 365 - 1 - 0.056515) < 1e-12);
  assert.equal(rates.borrowApr, 0.04);
});

test('rejects failed or incomplete campaigns instead of returning a fabricated zero', () => {
  assert.throws(() => parseMetrics('[FAIL] test_mainnetTuning()'));
  assert.throws(() => parseMetrics('[PASS] test_mainnetTuning()\n  fundedCryptoUsd: 0\n'));
});

test('keeper costs and exit shortfalls remain separate from funded crypto', () => {
  const m = { fundedCryptoUsd: 100, unconvertedUsd: 30, sourceEquityUsd: 750, loopDebtUsd: 3900,
    mainDebtUsd: 750, cashUsd: 0, harvests: 365, borrows: 20, rebalances: 50,
    repays: 0, pegUpdates: 365 };
  const r = score(m, { TVL: 1000, EXIT_BPS: 10 }, 2700);
  assert.ok(Math.abs(r.fundedReturnPct - 10) < 1e-10);
  assert.ok(r.markedOwnedReturnPct > r.netFundedReturnPct);
  assert.ok(r.netFundedReturnPct < 10);
  assert.ok(Math.abs(r.exitCoverageGapUsd - 4.65) < 1e-10);
  assert.ok(score(m, { TVL: 1000, EXIT_BPS: 10 }, 2700, 5).netFundedReturnPct < r.netFundedReturnPct);
});

test('higher APY cannot win through subsidy, insolvency or a missing asset case', () => {
  const pair = (candidate, apy, overrides = {}) => [0, 1].map(asset => ({ candidate,
    config: { ASSET: asset, DISCOUNT_BPS: 0, FEE_BPS: 500, ...overrides.config },
    metrics: { backingDeficitUsd: 0, minimumHf: 1.05, ...overrides.metrics },
    score: { netFundedReturnPct: apy },
  }));
  const cases = [ ...pair('viable', 4), ...pair('funding-gap', 8, { metrics: { backingDeficitUsd: 1 } }),
    ...pair('subsidy', 9, { config: { DISCOUNT_BPS: 10000 } }), pair('missing-BTC', 12)[0] ];
  assert.equal(select(cases).candidate, 'viable');
});

test('daily no-op budget and source funding losses cannot disappear from economics', () => {
  const m = { fundedCryptoUsd: 100, unconvertedUsd: 0, sourceEquityUsd: 500,
    loopDebtUsd: 3000, mainDebtUsd: 750, cashUsd: 0, backingDeficitUsd: 250,
    harvests: 0, borrows: 0, rebalances: 0, repays: 0, pegUpdates: 0 };
  const r = score(m, { TVL: 1000, EXIT_BPS: 10, DAYS: 365 }, 2700);
  assert.equal(r.maintenanceGas, 365 * 3_400_000);
  assert.ok(r.fundedReturnPct > 0);
  assert.ok(r.fundingAdjustedEconomicReturnPct < 0);
});
