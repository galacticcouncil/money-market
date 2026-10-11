// Five sequential, self-feeding rounds on actual Juicer contracts.
// Router/Aave boundaries are modeled; quote capacity is checked separately.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const root = fileURLToPath(new URL('../../', import.meta.url));
const sha = data => createHash('sha256').update(data).digest('hex');
export function inputRates(market, por) {
  const prime = por.demo_prime_card.tokens.find(x => x.token === 'prime');
  assert.ok(prime, 'PRIME-specific rate required; aggregate rate mixes other products');
  const primeApy = Number(prime.effective_rate) / 100;
  const supplyApr = Number(market.markets.PRIME.reserve.currentLiquidityRate) / 1e27;
  const borrowApr = Number(market.markets.HOLLAR.reserve.currentVariableBorrowRate) / 1e27;
  assert.ok(primeApy > -1 && primeApy < 1 && borrowApr >= 0);
  // Effective APY already includes Hastra's fee and wYLDS income. Do not add
  // either again. Daily rate preserves APY exactly rather than APY/365.
  return { primeApy, supplyApr, borrowApr,
    modeledYieldApr: 365 * (Math.pow(1 + primeApy, 1 / 365) - 1) + supplyApr };
}

export function parseMetrics(log) {
  assert.match(log, /\[PASS\] test_mainnetTuning/);
  const result = {};
  for (const [, key, amount] of log.matchAll(/^\s+([A-Za-z]+): (\d+)\s*$/gm)) {
    result[key] = key.endsWith('Usd') || key === 'minimumHf'
      ? Number(amount) / 1e18 : Number(amount);
  }
  for (const key of ['fundedCryptoUsd', 'backingDeficitUsd', 'harvests', 'borrows', 'minimumHf']) {
    assert.ok(Number.isFinite(result[key]), `missing ${key}`);
  }
  return result;
}

export function score(metrics, config, ethPrice, gasMultiplier = 1) {
  // Native receipt anchors plus rounded-up read-only native maintenance bounds:
  // peg 741k, settle 1.330M, rebalance <=1.167M in the measured fork state.
  // Charge ALL scheduled daily maintenance, including successful no-ops. A
  // borrowing rebalance replaces the routine 1.2M budget with the 2.8M anchor.
  // This daily model is not the existing keeper's five-minute slow-loop cadence.
  const onlineDays = (config.DAYS ?? 365) - (config.STRESS === 2 ? 14 : 0);
  const maintenanceGas = onlineDays * (800_000 + 1_400_000 + 1_200_000);
  const gas = 2_800_000 + maintenanceGas + metrics.harvests * 5_800_000
    + metrics.borrows * 1_500_000 + metrics.rebalances * (2_800_000 - 1_200_000)
    + metrics.repays * 1_600_000;
  const keeperUsd = gas * 5_536_035 / 1e18 * ethPrice * 1.2 * gasMultiplier;
  const grossSource = metrics.sourceEquityUsd + metrics.loopDebtUsd;
  const illustrativeExitCost = grossSource * config.EXIT_BPS / 10_000;
  const annualize = dollars => ((1 + dollars / config.TVL) ** (365 / (config.DAYS ?? 365)) - 1) * 100;
  return {
    keeperUsd, modeledNativeGas: gas, maintenanceGas,
    fundedReturnPct: annualize(metrics.fundedCryptoUsd),
    netFundedReturnPct: annualize(metrics.fundedCryptoUsd - keeperUsd),
    markedOwnedReturnPct: annualize(metrics.fundedCryptoUsd + metrics.unconvertedUsd - keeperUsd),
    fundingAdjustedEconomicReturnPct: annualize(metrics.fundedCryptoUsd + metrics.unconvertedUsd
      - keeperUsd - (metrics.backingDeficitUsd ?? 0)),
    // Not an executable exit proof: exposes the cost of closing the entire source.
    illustrativeExitCostUsd: illustrativeExitCost,
    exitCoverageGapUsd: Math.max(0, metrics.mainDebtUsd + illustrativeExitCost
      - metrics.sourceEquityUsd - metrics.cashUsd),
    totalDebtUsd: metrics.mainDebtUsd + metrics.loopDebtUsd,
  };
}

export function select(rows) {
  const groups = Map.groupBy(rows, r => r.candidate);
  return [...groups.entries()].map(([candidate, cases]) => ({
    candidate, cases,
    meanReturnPct: cases.reduce((sum, r) => sum + r.score.netFundedReturnPct, 0) / cases.length,
    eligible: cases.length === 2 && cases.every(r => r.metrics.backingDeficitUsd < 1e-5
      && r.metrics.minimumHf >= 1 && r.config.DISCOUNT_BPS === 0 && r.config.FEE_BPS === 500),
  })).filter(x => x.eligible).sort((a, b) => b.meanReturnPct - a.meanReturnPct)[0];
}

export function runRound(directory, round) {
  mkdirSync(directory, { recursive: true });
  const read = name => JSON.parse(readFileSync(resolve(directory, name)));
  const market = read('market.json'), por = read('hastra-por.json');
  const rates = inputRates(market, por);
  const base = { TVL: 10_000, YIELD_RAY: BigInt(Math.round(rates.modeledYieldApr * 1e27)).toString(),
    BORROW_RAY: market.markets.HOLLAR.reserve.currentVariableBorrowRate,
    SOURCE_BPS: 100, THRESHOLD_BPS: 10, EVERY: 1, MIN_HARVEST: 0,
    BORROW_EVERY: 1, TRANCHE: 1000, ENTRY_BPS: 5, EXIT_BPS: 7,
    DISCOUNT_BPS: 0, FEE_BPS: 500, STRESS: 0, DAYS: 365 };
  let previous;
  if (round > 1) {
    previous = read(`round-${round - 1}.json`);
    assert.ok(previous.winner, 'previous round must finish before the next');
    Object.assign(base, previous.winner.config);
    delete base.ASSET; delete base.SWAP_BPS;
  }
  let candidates;
  if (round === 1) candidates = [{ name: 'current', config: {} }];
  if (round === 2) candidates = [100, 50, 25, 15, 10].map(n => ({ name: `reserve-${n}`, config: { SOURCE_BPS: n } }));
  if (round === 3) candidates = [
    ...[0, 1, 5, 10, 25].map(n => ({ name: `threshold-${n}`, config: { THRESHOLD_BPS: n } })),
    ...[10, 25, 50, 100].map(n => ({ name: `minimum-${n}`, config: { THRESHOLD_BPS: 1, MIN_HARVEST: n } })),
    ...[3, 7].map(n => ({ name: `cadence-${n}`, config: { EVERY: n } })),
  ];
  if (round === 4) candidates = [1, 3, 7].flatMap(every => [250, 1000, 5000].map(tranche => ({
    name: `ramp-${every}d-${tranche}`, config: { BORROW_EVERY: every, TRANCHE: tranche },
  })));
  if (round === 5) candidates = [
    { name: 'selected', config: {} },
    { name: 'two-years', config: { DAYS: 730 } },
    { name: 'reserve-25', config: { SOURCE_BPS: 25 } },
    { name: 'reserve-25-worse-fills', config: { SOURCE_BPS: 25, ENTRY_BPS: 20, EXIT_BPS: 20 } },
    { name: 'small-vault', config: { TVL: 1000 } },
    { name: 'small-vault-minimum-10', config: { TVL: 1000, MIN_HARVEST: 10 } },
    { name: 'small-vault-minimum-25', config: { TVL: 1000, MIN_HARVEST: 25 } },
    { name: 'trailing-nav-rate', config: { YIELD_RAY: BigInt(Math.round((0.06100755708643359 + rates.supplyApr) * 1e27)).toString() } },
    { name: 'negative-spread', config: { STRESS: 1 } },
    { name: 'keeper-outage-14d', config: { STRESS: 2 } },
    { name: 'prime-gap-3pct', config: { STRESS: 3 } },
    { name: 'worse-fills', config: { ENTRY_BPS: 8, EXIT_BPS: 9 } },
    { name: 'holdout-quotes', config: { ENTRY_BPS: 7, EXIT_BPS: 7 } },
    { name: 'main-discount-50pct', config: { DISCOUNT_BPS: 5000 } },
    { name: 'main-discount-100pct', config: { DISCOUNT_BPS: 10000 } },
    { name: 'protocol-fee-1pct', config: { FEE_BPS: 100 } },
    { name: 'protocol-fee-zero', config: { FEE_BPS: 0 } },
    { name: 'full-discount-zero-fee', config: { DISCOUNT_BPS: 10000, FEE_BPS: 0 } },
  ];
  assert.ok(candidates, 'round must be 1..5');
  const rows = [];
  for (const candidate of candidates) for (const asset of [0, 1]) {
    const config = { ...base, ...candidate.config, ASSET: asset, SWAP_BPS: asset === 0 ? 60 : 100 };
    const id = `r${round}-${candidate.name}-${asset === 0 ? 'ETH' : 'BTC'}`;
    const env = { ...process.env, RUN_MAINNET_TUNING: 'true', FOUNDRY_GAS_LIMIT: '1000000000000',
      ...Object.fromEntries(Object.entries(config).map(([key, value]) => [`TUNE_${key}`, String(value)])) };
    const args = ['test', '--offline', '--evm-version', 'london', '--out', resolve(directory, 'out'),
      '--cache-path', resolve(directory, 'cache'), '--match-contract', 'MainnetTuningTest',
      '--match-test', 'test_mainnetTuning', '-vv'];
    let log;
    try { log = execFileSync('forge', args, { cwd: resolve(root, 'juicer-vault'), env,
      encoding: 'utf8', timeout: 600000, maxBuffer: 8 * 1024 * 1024 }); }
    catch (error) {
      writeFileSync(resolve(directory, `${id}.log`), String(error.stdout) + String(error.stderr));
      throw error;
    }
    writeFileSync(resolve(directory, `${id}.log`), log);
    const metrics = parseMetrics(log);
    rows.push({ id, candidate: candidate.name, config, metrics,
      score: score(metrics, config, Number(market.markets.ETH.price) / 1e8), logSha256: sha(log) });
    console.log(`${id}: net funded ${rows.at(-1).score.netFundedReturnPct.toFixed(4)}%, first crypto day ${metrics.firstCryptoDay}, harvests ${metrics.harvests}, deficit $${metrics.backingDeficitUsd.toFixed(4)}`);
    // Preserve completed evidence even if a subsequent scenario finds a failure.
    writeFileSync(resolve(directory, `round-${round}-partial.json`), JSON.stringify(rows, null, 2) + '\n');
  }
  const selected = round === 5 ? select(rows.filter(r => r.candidate === 'selected')) : select(rows);
  assert.ok(selected, 'no feasible winner; inspect the evidence instead of hiding failures');
  const winner = { candidate: selected.candidate, meanReturnPct: selected.meanReturnPct,
    config: selected.cases[0].config };
  const result = { round, rates, block: market.block, previousWinner: previous?.winner,
    scope: '365 days, flat crypto prices, no rescue funding; real Juicer contracts, mocked market and route boundaries. Return is funded crypto less modeled native keeper cost, before final unwind.',
    inputs: Object.fromEntries(['market.json', 'hastra-por.json'].map(f => [f, sha(readFileSync(resolve(directory, f)))])),
    rows, winner };
  writeFileSync(resolve(directory, `round-${round}.json`), JSON.stringify(result, null, 2) + '\n');
  console.log('ROUND WINNER', JSON.stringify(winner));
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  assert.ok(process.argv[2] && process.argv[3], 'usage: tune-mainnet.mjs evidence-directory round-number');
  runRound(resolve(process.argv[2]), Number(process.argv[3]));
}
