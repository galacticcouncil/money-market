import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { loadMath, poolQuote } from "./pressure-model.mjs";
import { units } from "./peg-model.mjs";
import {
  createState,
  totals,
  assertConservation,
  quoteMarks,
  arbitrage,
  advanceHsm,
  rebalanceInventory,
  settle,
  externalBuy,
  tradeStrategy,
  simulate,
  applyStress,
} from "./coupled-peg-model.mjs";

const file = process.env.PROPELLER_MARKET_SNAPSHOT;
const snapshot = file ? JSON.parse(readFileSync(file)) : null;
const math = snapshot ? loadMath(process.env.HYDRATION_MATH_ROOT) : null;
const scenario = (name, fn) => test(name, { skip: !snapshot }, fn);
function shock(collateralId, hollar) {
  const s = structuredClone(snapshot),
    c = s.hsm.collaterals.find((c) => c.id === collateralId),
    p = s.pools[c.config.poolId];
  const q = units(hollar),
    out = poolQuote(math.stable, p, 222, collateralId, q);
  p.reserves.find((r) => r.id === 222).balance = (
    BigInt(p.reserves.find((r) => r.id === 222).balance) + q
  ).toString();
  p.reserves.find((r) => r.id === collateralId).balance = (
    BigInt(p.reserves.find((r) => r.id === collateralId).balance) - out
  ).toString();
  return s;
}
scenario(
  "arbitrage redistributes existing HOLLAR without minting or burning",
  () => {
    const s = createState(snapshot, math),
      before = totals(s),
      marks = quoteMarks(s);
    assert.ok(arbitrage(s) > 0);
    assert.equal(totals(s)[222], before[222]);
    assert.equal(s.marketMinted + s.hsmMinted + s.hsmBurned, 0n);
    assert.ok(
      quoteMarks(s).find((p) => p.id === 43).bid >
        marks.find((p) => p.id === 43).bid
    );
    assert.ok(s.agent[43] < s.target[43]);
    assertConservation(s);
  }
);
scenario("no prefunded inventory means no assumed free arbitrage", () => {
  const s = createState(snapshot, math, { agentCapital: 0 });
  assert.equal(arbitrage(s), 0);
  assertConservation(s);
});
scenario(
  "execution and inventory risk threshold can close an arbitrage",
  () => {
    const s = createState(snapshot, math, { arbRiskBps: 1000 });
    assert.equal(arbitrage(s), 0);
    assertConservation(s);
  }
);
scenario("arbitrage outage prevents inventory trades", () => {
  const s = createState(snapshot, math, { arbOutage: [0, 24] });
  assert.equal(arbitrage(s), 0);
  s.now = 24;
  assert.ok(arbitrage(s) > 0);
  assertConservation(s);
});
scenario("no settlement capacity cannot replenish consumed PRIME", () => {
  const s = createState(snapshot, math, {
    primeDailyCapacity: 0,
    stableDailyCapacity: 0,
  });
  arbitrage(s);
  const prime = s.agent[43];
  rebalanceInventory(s);
  assert.equal(s.agent[43], prime);
  assert.equal(s.pending.length, 0);
  assert.equal(s.primeSubscribed, 0);
  assertConservation(s);
});
scenario(
  "PRIME subscriptions spend cash now and deliver only after delay",
  () => {
    const s = createState(snapshot, math, { primeDelayHours: 6 });
    arbitrage(s);
    const before = s.agent[43];
    rebalanceInventory(s);
    assert.ok(s.pending.some((p) => p.id === 43));
    assert.equal(s.agent[43], before);
    s.now = 5.99;
    settle(s);
    assert.equal(s.agent[43], before);
    s.now = 6;
    settle(s);
    assert.ok(s.agent[43] > before);
    assertConservation(s);
  }
);
scenario("settlement outage also delays already-funded deliveries", () => {
  const s = createState(snapshot, math, {
    settlementOutage: [2, 24],
    primeDelayHours: 6,
  });
  arbitrage(s);
  rebalanceInventory(s);
  const before = s.agent[43];
  s.now = 12;
  settle(s);
  assert.equal(s.agent[43], before);
  s.now = 24;
  settle(s);
  assert.ok(s.agent[43] > before);
  assertConservation(s);
});
scenario("aToken redemption uses shared cash and stops when empty", () => {
  const s = createState(snapshot, math, { cashFraction: 0 });
  arbitrage(s);
  rebalanceInventory(s);
  assert.equal(s.stableWithdrawn, 0);
  assert.ok(s.settlementBlockedCash > 0);
  assertConservation(s);
});
scenario(
  "small remaining money-market cash supports only a partial redemption",
  () => {
    const s = createState(snapshot, math, { cashFraction: 0.000001 });
    arbitrage(s);
    const initial = s.mmCash[1002] + s.mmCash[1003];
    rebalanceInventory(s);
    assert.ok(
      s.stableWithdrawn > 0 && s.stableWithdrawn <= Number(initial) / 1e6 + 1e-6
    );
    assert.ok(s.mmCash[1002] >= 0n && s.mmCash[1003] >= 0n);
    assertConservation(s);
  }
);
scenario(
  "HSM buyback spends collateral and decreases its existing bucket",
  () => {
    const s = createState(shock(1003, 700000), math),
      burn = s.hsm.burn,
      holding = s.hsm.rows.reduce((n, r) => n + r.holding, 0n);
    advanceHsm(s, 3600);
    assert.ok(s.hsmBurned > 0n && s.hsm.burn < burn);
    assert.ok(s.hsm.rows.reduce((n, r) => n + r.holding, 0n) < holding);
    assertConservation(s);
  }
);
scenario("HSM premium-side mint is backed by newly received collateral", () => {
  const input = structuredClone(snapshot),
    p = input.pools[110];
  p.reserves.find((r) => r.id === 222).balance = units(300000).toString();
  p.reserves.find((r) => r.id === 1003).balance = units(1500000, 6).toString();
  const s = createState(input, math),
    before = s.hsm.rows.find((r) => r.id === 1003).holding;
  advanceHsm(s, 60);
  assert.ok(s.hsmMinted > 0n);
  assert.ok(s.hsm.rows.find((r) => r.id === 1003).holding > before);
  assert.equal(s.hsm.burn, s.initialBurn + s.hsmMinted - s.hsmBurned);
  assertConservation(s);
});
scenario(
  "HSM minting respects both issuance capacity and holdings ceiling",
  () => {
    for (const binding of ["capacity", "holdings"]) {
      const input = structuredClone(snapshot),
        p = input.pools[110];
      p.reserves.find((r) => r.id === 222).balance = units(300000).toString();
      p.reserves.find((r) => r.id === 1003).balance = units(
        1500000,
        6
      ).toString();
      if (binding === "capacity") {
        const f = input.facilitators.find(
          (f) => f.label === "HOLLAR Stability Module"
        );
        f.bucketCapacity = f.bucketLevel;
      } else {
        const c = input.hsm.collaterals.find((c) => c.id === 1003);
        c.config.maxInHolding = c.balance;
      }
      const s = createState(input, math);
      advanceHsm(s, 60);
      assert.equal(s.hsmMinted, 0n);
      assertConservation(s);
    }
  }
);
scenario("donating HSM collateral does not create extra burn capacity", () => {
  const input = shock(1003, 700000),
    f = input.facilitators.find((f) => f.label === "HOLLAR Stability Module");
  f.bucketLevel = "0";
  const s = createState(input, math, { hsmDonation: 1e6 });
  advanceHsm(s, 3600);
  assert.equal(s.hsmBurned, 0n);
  assertConservation(s);
});
scenario(
  "external HOLLAR demand spends finite independent cash, not arb profits",
  () => {
    const s = createState(shock(1003, 700000), math, {
      buyerCoverage: 0.01,
      buyerDailyCapacity: 1e9,
    });
    const initial = s.buyerCash;
    externalBuy(s, 86400);
    assert.ok(s.buyerCash < initial && s.buyerH > 0n);
    assert.equal(s.hsmBurned + s.marketBurned + s.externalDebtRepaid, 0n);
    assert.ok(s.stableSupplied > 0);
    assertConservation(s);
  }
);
scenario("external borrower repayment burns only the purchased HOLLAR", () => {
  const s = createState(shock(1003, 700000), math, {
    buyerCoverage: 0.01,
    buyerDailyCapacity: 1e9,
    buyerMode: "repay",
  });
  externalBuy(s, 86400);
  assert.ok(s.externalDebtRepaid > 0n);
  assert.equal(s.buyerH, 0n);
  assertConservation(s);
});
scenario("zero buyer funding cannot be turned into organic demand", () => {
  const s = createState(shock(1003, 700000), math, {
    buyerCoverage: 0,
    buyerDailyCapacity: 1e9,
  });
  externalBuy(s, 86400);
  assert.equal(s.buyerH, 0n);
  assertConservation(s);
});
scenario(
  "the entry guard queues demand instead of executing a bad fill",
  () => {
    const s = createState(snapshot, math, { entryFloor: 1 });
    tradeStrategy(s, 1e6, 3600);
    assert.equal(s.marketMinted, 0n);
    assert.ok(s.guardCount > 0);
    assertConservation(s);
  }
);
scenario(
  "entry and exit update inventory and repay only actual proceeds",
  () => {
    const s = createState(snapshot, math, { entryFloor: 0.9, exitFloor: 0.9 });
    tradeStrategy(s, 10000, 3600);
    assert.ok(s.debt > 0n && s.strategyPrime > 0n);
    const minted = s.marketMinted;
    tradeStrategy(s, 0, 3600);
    assert.ok(s.marketBurned > 0n && s.marketBurned <= minted);
    assertConservation(s);
  }
);
scenario(
  "market mint-cap increases are permissions, not LP or reserve funding",
  () => {
    const a = createState(snapshot, math, { mintCapsRaised: false }),
      b = createState(snapshot, math, { mintCapsRaised: true });
    assert.deepEqual(totals(a), totals(b));
    assert.deepEqual(a.mmCash, b.mmCash);
    assert.equal(a.hsm.burn, b.hsm.burn);
  }
);
scenario(
  "coupled short run records queues, daily prices, and conservation",
  () => {
    const r = simulate(snapshot, math, {
      days: 2,
      warmupHours: 6,
      rampDays: 30,
      buyerCoverage: 1,
    });
    assert.equal(r.daily.length, 2);
    assert.equal(r.conservation, true);
    assert.ok(
      r.arbCount > 0 && r.primeSubscribed > 0 && r.fulfilledFraction > 0
    );
    assert.ok(r.buyerSpent <= r.grossRequested && r.buyerSpent >= 0);
    assert.ok(r.agentCash >= 0 && r.mmCash[1002] >= 0 && r.mmCash[1003] >= 0);
  }
);
scenario(
  "external PRIME valuation cannot relax the oracle-based entry guard",
  () => {
    const a = createState(snapshot, math, { primeFairPrice: 1.2 }),
      b = createState(snapshot, math);
    tradeStrategy(a, 10000, 3600);
    tradeStrategy(b, 10000, 3600);
    assert.equal(a.debt, b.debt);
    assert.equal(a.strategyPrime, b.strategyPrime);
    assert.notEqual(
      quoteMarks(a).find((r) => r.id === 43).bid,
      quoteMarks(b).find((r) => r.id === 43).bid
    );
    assertConservation(a);
    assertConservation(b);
  }
);
scenario(
  "LP withdrawals remove real assets once and preserve the global ledger",
  () => {
    const s = createState(snapshot, math, {
      lpWithdrawal: { hour: 24, fraction: 0.5, pools: [143] },
    });
    const before = BigInt(s.pools[143].reserves[0].balance);
    applyStress(s);
    assert.equal(BigInt(s.pools[143].reserves[0].balance), before);
    s.now = 24;
    applyStress(s);
    const after = BigInt(s.pools[143].reserves[0].balance);
    assert.equal(after, before - before / 2n);
    applyStress(s);
    assert.equal(BigInt(s.pools[143].reserves[0].balance), after);
    assert.equal(s.stressLog.length, 1);
    assertConservation(s);
  }
);
scenario(
  "outside lender withdrawals constrain cash without burning pool aTokens",
  () => {
    const s = createState(snapshot, math, {
        cashWithdrawal: { hour: 0, fraction: 1 },
      }),
      before = totals(s);
    applyStress(s);
    assert.equal(s.mmCash[1002] + s.mmCash[1003], 0n);
    assert.deepEqual(totals(s), before);
    arbitrage(s);
    rebalanceInventory(s);
    assert.equal(s.stableWithdrawn, 0);
    assertConservation(s);
  }
);
scenario("entry pause does not turn off exits", () => {
  const s = createState(snapshot, math, {
    entryFloor: 0.9,
    exitFloor: 0.9,
    entryOutage: [1, 24],
  });
  tradeStrategy(s, 10000, 3600);
  const debt = s.debt;
  s.now = 1;
  tradeStrategy(s, 100000, 3600);
  assert.equal(s.debt, debt);
  tradeStrategy(s, 0, 3600);
  assert.ok(s.debt < debt);
  assertConservation(s);
});
