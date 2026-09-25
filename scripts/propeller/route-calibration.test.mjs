import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  calibrate,
  lossBps,
  maximumInput,
  sellPrime,
} from "./route-calibration.mjs";
import { loadMath, poolQuote, QuoteRejected } from "./pressure-model.mjs";
const snapshot = JSON.parse(
  readFileSync(
    process.env.PROPELLER_MARKET_SNAPSHOT ||
      new URL("./fixtures/market-20260922.json", import.meta.url)
  )
);
const math = loadMath(process.env.HYDRATION_MATH_ROOT);
const W = 10n ** 18n;
test("loss measurement respects decimals and does not hide favorable fills", () => {
  assert.equal(lossBps(W, 990000n, 100000000n), 100);
  assert.equal(lossBps(1000000n, (W * 101n) / 100n, 100000000n, true), -100);
});
test("infeasible marginal quote has zero admissible size", () => {
  assert.equal(
    maximumInput(
      (q) => (q * 98n) / 100n,
      (o, i) => o * 100n >= i * 99n,
      1000n * W
    ),
    0n
  );
});
test("capacity search never rounds an unsafe boundary upwards", () => {
  const max = maximumInput(
    (q) => q,
    (o, i) => i <= 1234n * W + 5n,
    5000n * W
  );
  assert.equal(max, 1234n * W + 5n);
});
test("capacity search handles rejected quotes without hiding unexpected errors", () => {
  assert.equal(
    maximumInput(
      () => {
        throw new QuoteRejected();
      },
      () => true,
      W
    ),
    0n
  );
  assert.equal(
    maximumInput(
      () => 0n,
      () => true,
      W
    ),
    0n
  );
  const boundary = 1234n * W + 5n;
  assert.equal(
    maximumInput(
      (q) => {
        if (q > boundary) throw new QuoteRejected();
        return q;
      },
      () => true,
      5000n * W
    ),
    boundary
  );
  assert.throws(
    () =>
      maximumInput(
        () => {
          throw new TypeError("broken quote");
        },
        () => true,
        W
      ),
    TypeError
  );
  assert.throws(
    () =>
      maximumInput(
        (q) => q,
        () => {
          throw new Error("broken floor");
        },
        W
      ),
    /broken floor/
  );
});
test("capacity search respects zero and sub-HOLLAR input limits", () => {
  assert.equal(
    maximumInput(
      () => {
        throw new Error("no quote expected");
      },
      () => true,
      0n
    ),
    0n
  );
  const limit = W / 2n;
  assert.equal(
    maximumInput(
      (q) => {
        assert.ok(q <= limit);
        return q;
      },
      () => true,
      limit
    ),
    limit
  );
});
test("refill pays the trader from pool HOLLAR and preserves both inventories", () => {
  const p = snapshot.pools[143],
    input = 10000n * 1000000n;
  const r = sellPrime(math.stable, p, input);
  assert.equal(
    BigInt(r.pool.reserves[0].balance) - BigInt(p.reserves[0].balance),
    input
  );
  assert.equal(
    BigInt(p.reserves[1].balance) - BigInt(r.pool.reserves[1].balance),
    r.output
  );
  assert.equal(r.output, poolQuote(math.stable, p, 43, 222, input));
});
test("oracle-only improvement is not confused with eventual pool-peg repricing", () => {
  const r = calibrate(snapshot, math, 106080552n);
  const immediate = r.cases.find(
    (x) => x.name === "reference-only-peg-not-yet-updated"
  );
  const settled = r.cases.find(
    (x) => x.name === "reference-and-peg-updated-no-refill"
  );
  assert.ok(
    immediate.maxOneShotEntryHollar[25] > settled.maxOneShotEntryHollar[25]
  );
});
test("tighter floors have no more capacity than looser ones", () => {
  for (const c of calibrate(snapshot, math, 106080552n).cases) {
    const v = c.maxOneShotEntryHollar;
    assert.ok(v[10] <= v[25] && v[25] <= v[50] && v[50] <= v[100]);
  }
});
test("six-TVL throughput includes gross loop exposure and linear retention", () => {
  const r = calibrate(snapshot, math, 106080552n);
  assert.equal(r.throughput.length, 12);
  const row = r.throughput.find(
    (x) => x.tvl === 100000000 && x.tranche === 1000
  );
  assert.ok(row.grossHollar > row.mainHollar);
  assert.ok(row.daysAtOneCallPerFiveMinutes > 90);
  assert.equal(
    row.worstCaseRetentionHollar[100],
    row.worstCaseRetentionHollar[25] * 4
  );
});
test(
  "pinned SDK quotes exactly match native pool-143 and folded Aave routes",
  { skip: !process.env.PROPELLER_ROUTE_EVIDENCE },
  () => {
    const evidence = JSON.parse(
      readFileSync(process.env.PROPELLER_ROUTE_EVIDENCE)
    );
    assert.equal(evidence.fork.block, String(snapshot.block));
    const rows = evidence.routeCalibration.rows.filter(
      (q) =>
        [43, 1043, 222].includes(q.input) &&
        [43, 1043, 222].includes(q.output) &&
        q.outputAmount
    );
    assert.ok(rows.length >= 35);
    for (const q of rows) {
      assert.equal(
        poolQuote(
          math.stable,
          snapshot.pools[143],
          q.input === 1043 ? 43 : q.input,
          q.output === 1043 ? 43 : q.output,
          BigInt(q.amount)
        ),
        BigInt(q.outputAmount)
      );
      assert.equal(
        q.strict100bps,
        BigInt(q.outputAmount) >= BigInt(q.minOut100bps)
      );
    }
  }
);
