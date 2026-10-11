import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadMath } from "./pressure-model.mjs";
import {
  refillCapacity,
  minimumRefill,
  validation,
} from "./prime-replenishment.mjs";
test("bridge capacity refills linearly, rounds down and never exceeds limit", () => {
  assert.equal(refillCapacity(100n, 20n, 0n, 43200n), 70n);
  assert.equal(refillCapacity(100n, 20n, 0n, 86400n), 100n);
  assert.equal(refillCapacity(100n, 0n, 0n, 1n), 0n);
});
test("bridge capacity rejects future timestamps or invalid balances", () => {
  assert.throws(() => refillCapacity(100n, 20n, 10n, 9n));
  assert.throws(() => refillCapacity(100n, 101n, 0n, 0n));
});
test("minimum refill is exact at native-unit boundary", () => {
  assert.equal(
    minimumRefill((x) => x >= 150000000001n, 300000000000n),
    150000000001n
  );
  assert.equal(
    minimumRefill(() => true, 10n),
    0n
  );
  assert.equal(
    minimumRefill(() => false, 10n),
    null
  );
});
test(
  "pinned pricing and refill evidence does not turn turnover into a guarantee",
  { skip: !process.env.PRIME_VALIDATION_EVIDENCE },
  () => {
    const root = process.env.PRIME_VALIDATION_EVIDENCE,
      j = (f) => JSON.parse(readFileSync(`${root}/${f}.json`));
    const r = validation(
      j("market"),
      j("solana"),
      j("history"),
      loadMath(process.env.HYDRATION_MATH_ROOT)
    );
    assert.equal(r.providerCommitmentVerified, false);
    assert.ok(r.history.netPrimeSold < 0);
    assert.ok(r.history.daysUnder1000UsdSales > 20);
    assert.ok(r.scenarios[0].quotes[0].edgeBps < 0);
    assert.ok(r.scenarios[1].quotes[0].edgeBps > 0);
    for (const c of r.scenarios) {
      const q = c.minimumPrimeRefillFor1000HollarEntry;
      assert.ok(q[25] >= q[50] && q[50] >= q[100]);
    }
    assert.equal(r.ramp.length, 6);
    assert.ok(
      r.ramp.find((x) => x.tvl === 1000000).hollarPerDayFor30DayRamp > 150000
    );
    assert.ok(r.redemption.nominalCashGap > 90000);
  }
);
