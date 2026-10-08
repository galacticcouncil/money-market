import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadMath, poolQuote, hsmCapacity, usd } from "./pressure-model.mjs";
import {
  units,
  stateFrom,
  inject,
  candidate,
  execute,
  conservation,
  simulate,
  requiredPool,
  balancedPool,
  afterSale,
  saleCapacity,
} from "./peg-model.mjs";
import { requiredTopUp } from "./peg-model.mjs";

const file = process.env.PROPELLER_MARKET_SNAPSHOT;
const snapshot = file ? JSON.parse(readFileSync(file)) : null;
const math = snapshot ? loadMath(process.env.HYDRATION_MATH_ROOT) : null;
function scenario(name, fn) {
  test(name, { skip: !snapshot }, fn);
}
test("amount conversion preserves six-decimal stress amounts", () => {
  assert.equal(units(123.456789), 123456789n * 10n ** 12n);
  assert.equal(units(123.456789, 6), 123456789n);
});
scenario(
  "exact-output BUY quote agrees with exact-input within fee and rounding dust",
  () => {
    const p = snapshot.pools[110],
      h = units(100);
    const cost = poolQuote(math.stable, p, 1003, 222, h, true);
    // Runtime charges buy fees on input, sell fees on output. They are not
    // algebraic inverses; the discrepancy here is below ten micro-HOLLAR.
    const reverse = poolQuote(math.stable, p, 1003, 222, cost);
    assert.ok(reverse > h - units(0.00001) && reverse < h + units(0.00001));
    assert.ok(cost > 99000000n && cost < 100100000n);
  }
);
scenario(
  "runtime quote direction and buyback-fee gate match official HSM math",
  () => {
    const s = stateFrom(snapshot);
    inject(s, math, 1e6);
    for (const r of s.rows) {
      const t = candidate(s, math, r);
      assert.ok(t);
      const adjusted = JSON.parse(
        math.hsm.calculate_buyback_price_with_fee(
          t.cost.toString(),
          t.q.toString(),
          String(r.config.buyBackFee / 1e6)
        )
      ).map(BigInt);
      assert.equal(
        t.payment,
        (t.q * adjusted[0] + adjusted[1] - 1n) / adjusted[1]
      );
      assert.ok(t.payment >= t.cost);
      const before = s.burn;
      execute(s, r, t);
      assert.equal(s.burn, before - t.q);
      conservation(s);
    }
  }
);
scenario("old static HSM helper uses the same corrected BUY direction", () => {
  const s = stateFrom(snapshot);
  inject(s, math, 1e6);
  const updated = structuredClone(snapshot);
  for (const r of s.rows) updated.pools[r.config.poolId] = r.pool;
  assert.ok(hsmCapacity(updated, math).every((r) => r.priceEligible));
});
scenario("funded pools at the peg do not trigger buybacks", () => {
  const s = stateFrom(snapshot);
  for (const r of s.rows) {
    r.pool = balancedPool(r.pool, r.id, 2e6);
    assert.equal(candidate(s, math, r), null);
  }
});
scenario(
  "zero collateral or zero burn bucket independently prevent intervention",
  () => {
    for (const empty of ["holding", "burn"]) {
      const s = stateFrom(snapshot);
      inject(s, math, 1e6);
      for (const r of s.rows) {
        if (empty === "holding") r.holding = 0n;
        else s.burn = 0n;
        assert.equal(candidate(s, math, r), null);
      }
    }
  }
);
scenario(
  "OCW will not burn a candidate larger than its remaining bucket",
  () => {
    const s = stateFrom(snapshot);
    inject(s, math, 1e6);
    const t = candidate(s, math, s.rows[0]);
    assert.ok(t);
    s.burn = t.q - 1n;
    assert.equal(candidate(s, math, s.rows[0]), null);
  }
);
scenario("flash capacity and minimum trade size are separate gates", () => {
  const s = stateFrom(snapshot);
  inject(s, math, 1e6);
  s.flashLimit = 0n;
  assert.equal(candidate(s, math, s.rows[0]), null);
  s.flashLimit = units(1e9);
  s.minArb = units(1e9);
  assert.equal(candidate(s, math, s.rows[0]), null);
});
scenario(
  "a full shock consumes reserves and preserves exact token conservation",
  () => {
    const initial = stateFrom(snapshot);
    const holdings = initial.rows.reduce(
      (sum, r) => sum + usd(r.holding, r.decimals),
      0
    );
    const r = simulate(snapshot, math, { sales: [1.2e6], days: 7 });
    assert.ok(r.burned > 0 && r.burned <= usd(initial.burn));
    assert.ok(Math.abs(r.burned + r.burnRemaining - usd(initial.burn)) < 1e-6);
    assert.ok(Math.abs(r.spent + r.hsmRemaining - holdings) < 1e-6);
    assert.ok(r.hsmRemaining >= 0 && r.burnRemaining >= 0);
    assert.ok(r.finalPrice > r.minimumPrice);
    assert.equal(r.conservation, true);
  }
);
scenario(
  "larger mint ceilings alone produce identical downside protection",
  () => {
    const high = structuredClone(snapshot);
    for (const f of high.facilitators) f.bucketCapacity = units(1e9).toString();
    assert.deepEqual(
      simulate(high, math, { sales: [1.2e6], days: 2 }),
      simulate(snapshot, math, { sales: [1.2e6], days: 2 })
    );
  }
);
scenario(
  "collateral donations do not remove the independent burn constraint",
  () => {
    const base = simulate(snapshot, math, { sales: [1.2e6], days: 2 });
    const funded = simulate(snapshot, math, {
      sales: [1.2e6],
      days: 2,
      donate: 2e6,
    });
    const bucket =
      Number(
        snapshot.facilitators.find((f) => f.label === "HOLLAR Stability Module")
          .bucketLevel
      ) / 1e18;
    assert.ok(funded.burned <= bucket && base.burned <= bucket);
    // Donations may change allocation between collaterals when one sleeve runs
    // dry, but cannot expand the shared HOLLAR burn budget.
    assert.ok(Math.abs(funded.burned + funded.burnRemaining - bucket) < 1e-6);
    const initial = stateFrom(snapshot);
    const holdings = initial.rows.reduce(
      (sum, r) => sum + usd(r.holding, r.decimals),
      0
    );
    assert.ok(
      Math.abs(funded.spent + funded.hsmRemaining - holdings - 2e6) < 1e-6
    );
    assert.ok(funded.hsmRemaining > 1.9e6);
  }
);
scenario(
  "funded and explicitly counterfactual burn expansion improves recovery",
  () => {
    const r = simulate(snapshot, math, {
      sales: [1.2e6],
      days: 7,
      donate: 2e6,
      hypotheticalBurn: 2e6,
    });
    assert.ok(r.finalPrice > 0.99);
    assert.ok(r.burned > 300000);
  }
);
scenario(
  "an offline keeper cannot improve the instantaneous sell price",
  () => {
    const base = simulate(snapshot, math, { sales: [1e6], days: 2 });
    const off = simulate(snapshot, math, {
      sales: [1e6],
      days: 2,
      outageDays: 2,
    });
    assert.equal(base.minimumPrice, off.minimumPrice);
    assert.equal(off.burned, 0);
    assert.equal(off.finalPrice, off.minimumPrice);
  }
);
scenario("half service delays intervention, not initial price impact", () => {
  const base = simulate(snapshot, math, { sales: [1e6], days: 1 });
  const slow = simulate(snapshot, math, {
    sales: [1e6],
    days: 1,
    serviceEvery: 2,
  });
  assert.equal(base.minimumPrice, slow.minimumPrice);
  assert.ok(slow.hoursBelow99 >= base.hoursBelow99);
});
scenario(
  "pool sizing constrains terminal price, not just average execution",
  () => {
    const template = snapshot.pools[110],
      flow = 1e6,
      floor = 0.99;
    const total = requiredPool(math.stable, template, 1003, flow, floor);
    const sized = afterSale(
      math.stable,
      balancedPool(template, 1003, total * 1.00001),
      1003,
      flow
    );
    const small = afterSale(
      math.stable,
      balancedPool(template, 1003, total * 0.99),
      1003,
      flow
    );
    assert.ok(sized.endPrice >= floor && sized.averagePrice > sized.endPrice);
    assert.ok(small.endPrice < floor);
    assert.ok(
      Math.abs(
        saleCapacity(
          math.stable,
          balancedPool(template, 1003, total),
          1003,
          floor
        ) - flow
      ) < 1
    );
  }
);
scenario(
  "tighter bands require more depth; balanced depth scales with pressure",
  () => {
    const p = snapshot.pools[110];
    const a = requiredPool(math.stable, p, 1003, 1e5, 0.99),
      b = requiredPool(math.stable, p, 1003, 1e6, 0.99);
    assert.ok(Math.abs(b / a - 10) < 0.001);
    assert.ok(requiredPool(math.stable, p, 1003, 1e5, 0.995) > a);
    assert.ok(requiredPool(math.stable, p, 1003, 1e5, 0.98) < a);
  }
);
scenario(
  "additional LP sizing respects existing imbalance and existing liquidity",
  () => {
    const p = snapshot.pools[110];
    assert.equal(requiredTopUp(math.stable, p, 1003, 1e5, 0.99), 0);
    const extra = requiredTopUp(math.stable, p, 1003, 6e5, 0.99);
    assert.ok(extra > 0);
    const topped = structuredClone(p);
    for (const r of topped.reserves)
      r.balance = (
        BigInt(r.balance) + units((extra * 1.0001) / 2, r.info.decimals)
      ).toString();
    assert.ok(afterSale(math.stable, topped, 1003, 6e5).endPrice >= 0.99);
  }
);
