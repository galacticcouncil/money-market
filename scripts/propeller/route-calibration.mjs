// Exact SDK pool math plus explicitly conditional reference/refill scenarios.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { loadMath, poolQuote, capacity, TVLS } from "./pressure-model.mjs";

const H = 222,
  P = 43,
  WAD = 10n ** 18n;
const balance = (pool, id) =>
  BigInt(pool.reserves.find((r) => r.id === id).balance);
export function lossBps(input, output, price8, reverse = false) {
  const fair = reverse
    ? (input * price8 * 10n ** 12n) / 100000000n
    : (input * 100000000n) / price8 / 10n ** 12n;
  assert.ok(fair > 0n);
  return Number(((fair - output) * 1000000n) / fair) / 100;
}
export function maximumInput(quote, acceptable, limit) {
  if (!acceptable(quote(1n * WAD), 1n * WAD)) return 0n;
  let lo = 0n,
    hi = limit;
  for (let i = 0; i < 128 && hi > lo; i++) {
    const mid = (lo + hi + 1n) / 2n;
    try {
      if (acceptable(quote(mid), mid)) lo = mid;
      else hi = mid - 1n;
    } catch {
      hi = mid - 1n;
    }
  }
  return lo;
}
export function sellPrime(stable, pool, amount) {
  const copy = structuredClone(pool);
  const output = poolQuote(stable, copy, P, H, amount);
  copy.reserves.find((r) => r.id === P).balance = (
    balance(copy, P) + amount
  ).toString();
  copy.reserves.find((r) => r.id === H).balance = (
    balance(copy, H) - output
  ).toString();
  return { pool: copy, output };
}
export function calibrate(snapshot, math, reference8) {
  const current = BigInt(snapshot.markets.PRIME.price),
    original = snapshot.pools[143];
  assert.ok(current > 0n && reference8 > 0n);
  const refreshed = structuredClone(original);
  const primeIndex = refreshed.reserves.findIndex((r) => r.id === P);
  refreshed.pegs.current[primeIndex] = [reference8.toString(), "100000000"];
  const cases = [
    { name: "observed", price: current, pool: original },
    {
      name: "reference-only-peg-not-yet-updated",
      price: reference8,
      pool: original,
    },
    {
      name: "reference-and-peg-updated-no-refill",
      price: reference8,
      pool: refreshed,
    },
  ];
  for (const refill of [50000, 100000, 150000]) {
    const next = sellPrime(math.stable, refreshed, BigInt(refill) * 1000000n);
    cases.push({
      name: `reference-peg-refill-${refill}`,
      price: reference8,
      pool: next.pool,
      externallySuppliedPrime: refill,
      hollarPaidToTrader: Number(next.output) / 1e18,
    });
  }
  const c = capacity(snapshot);
  const result = {
    block: snapshot.block,
    oraclePrice: Number(current) / 1e8,
    independentReference: Number(reference8) / 1e8,
    dependencies: math.dependencies,
    scope:
      "Observed state plus conditional wYLDS=$1/reference-update/full-peg-update/trader-inventory scenarios. Not a recommended oracle update or committed replenishment.",
    cases: [],
    throughput: [],
  };
  for (const scenario of cases) {
    const quote = (q) => poolQuote(math.stable, scenario.pool, H, P, q);
    const rows = [
      1, 10, 100, 1000, 2500, 5000, 10000, 25000, 50000, 100000,
    ].map((dollars) => {
      const amount = BigInt(dollars) * WAD,
        output = quote(amount);
      const primeIn =
        (BigInt(dollars) * 100000000n * 1000000n) / scenario.price;
      return {
        hollar: dollars,
        primeOut: Number(output) / 1e6,
        entryLossBps: lossBps(amount, output, scenario.price),
        exitLossBps: lossBps(
          primeIn,
          poolQuote(math.stable, scenario.pool, P, H, primeIn),
          scenario.price,
          true
        ),
      };
    });
    const limits = Object.fromEntries(
      [10, 25, 50, 100].map((bps) => {
        const q = maximumInput(
          quote,
          (out, input) =>
            out * scenario.price * 10n ** 12n * 10000n >=
            input * 100000000n * BigInt(10000 - bps),
          balance(scenario.pool, H) * 10n
        );
        return [bps, Number(q / WAD)];
      })
    );
    result.cases.push({
      name: scenario.name,
      oraclePrice: Number(scenario.price) / 1e8,
      externallySuppliedPrime: scenario.externallySuppliedPrime ?? 0,
      hollarPaidToTrader: scenario.hollarPaidToTrader ?? 0,
      quotes: rows,
      maxOneShotEntryHollar: limits,
    });
  }
  for (const tvl of TVLS)
    for (const tranche of [1000, 5000]) {
      const main = (tvl * (c.ltv[0] + c.ltv[1])) / 2,
        gross = main * c.leverage;
      const calls = Math.ceil(gross / tranche);
      result.throughput.push({
        tvl,
        tranche,
        mainHollar: main,
        grossHollar: gross,
        idealizedEntryCalls: calls,
        daysAtOneCallPerFiveMinutes: calls / 288,
        keeperBorrowCallsLowerBound: Math.ceil((gross - main) / tranche),
        keeperOnlyDaysAtOneCallPerFiveMinutes:
          Math.ceil((gross - main) / tranche) / 288,
        requiredRefillHollarPerDayFor30DayRamp: gross / 30,
        worstCaseRetentionHollar: Object.fromEntries(
          [10, 25, 50, 100].map((bps) => [bps, (gross * bps) / 10000])
        ),
      });
    }
  result.admission =
    "Initial deposits call _fundDeploy in full; deployTranche only caps pokeBorrow. Limits above are snapshot average-fill limits, not cumulative daily capacity. Concurrent fills and oracle/peg changes require fresh quotes. No native circuit-breaker bypass is implied.";
  return result;
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const [snapshotFile, referenceFile, output] = process.argv.slice(2);
  assert.ok(
    output,
    "usage: route-calibration.mjs snapshot.json reference.json output.json"
  );
  const reference = JSON.parse(readFileSync(referenceFile));
  assert.equal(reference.accounts.length, 1);
  const a = reference.accounts[0];
  assert.equal(a.fresh, true, "reference was stale when collected");
  const r = calibrate(
    JSON.parse(readFileSync(snapshotFile)),
    loadMath(process.env.HYDRATION_MATH_ROOT),
    (BigInt(a.priceRaw) * 100000000n) / BigInt(a.scale)
  );
  r.inputs = Object.fromEntries(
    [snapshotFile, referenceFile].map((file) => [
      file,
      createHash("sha256").update(readFileSync(file)).digest("hex"),
    ])
  );
  writeFileSync(output, JSON.stringify(r, null, 2) + "\n");
  console.log(
    JSON.stringify(
      r.cases.map(
        ({ name, maxOneShotEntryHollar, externallySuppliedPrime }) => ({
          name,
          maxOneShotEntryHollar,
          externallySuppliedPrime,
        })
      ),
      null,
      2
    )
  );
}
