import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { capacity } from "./pressure-model.mjs";
import {
  headroom,
  market,
  sellableYield,
  simulate,
  POLICIES,
  PATHS,
  runComparison,
} from "./interest-policy-model.mjs";

const c = {
  leverage: 1 / (1 - 0.88 / 1.05),
  ltv: [0.75, 0.8],
  price: [3000, 60000],
  borrowApr: 0.044016888917752794,
  marketMintRoom: 1.3e6,
  primeSupplyRoom: 6.4e6,
  primeIsolationRoom: 4.8e6,
  ethSupplyRoom: 8.9e6,
  btcSupplyRoom: 1.6e6,
};
const near = (a, b, tolerance = 1e-7) =>
  assert.ok(Math.abs(a - b) <= tolerance, `${a} != ${b}`);

test("accrued interest reduces new borrowing, never creates proceeds", () => {
  assert.equal(headroom(20000, 0.75, 10000), 5000);
  assert.equal(headroom(20000, 0.75, 10100), 4900);
  assert.equal(headroom(10000, 0.75, 10100), 0);
  const debt = 10100,
    source = 10000,
    extra = headroom(20000, 0.75, debt);
  assert.equal(debt + extra - (source + extra), 100);
});

test("same-token principal is excluded from sellable yield", () => {
  near(sellableYield(1.1, 1), 0.1);
  assert.equal(sellableYield(1, 1), 0);
  assert.equal(sellableYield(0.9, 1), 0);
  // A late depositor's full contribution is principal, not a pro-rata share of
  // earlier holders' accumulated yield. An aggregate floor alone cannot decide it.
  assert.equal(sellableYield(1.1, 1.1), 0);
});

test("current policy's apparent extra yield has an explicit Main-interest subsidy", () => {
  const r = simulate(c, { policy: "current" });
  assert.ok(r.userTokenReturnPct > r.unsubsidizedTokenEquivalentPct);
  near(r.governanceFunding, r.mainInterest);
  assert.equal(r.reverseSwaps, 0);
  assert.equal(r.unfundedExits, 4);
  assert.equal(r.minimumPrincipalSupport, 0);
});

test("fee is charged on gross collateral harvest before Main servicing", () => {
  for (const policy of POLICIES) {
    const r = simulate(c, { policy });
    near(
      r.fees,
      r.vaults.reduce((n, v) => n + v.harvested * (1 - r.swapCost) * r.fee, 0)
    );
    near(r.reverseCosts, r.reverseVolume * r.swapCost);
  }
});

test("harvest-time repayment reduces compound interest but not delay interest", () => {
  const current = simulate(c, { policy: "current" });
  const paid = simulate(c, { policy: "harvest" });
  assert.ok(paid.mainInterest < current.mainInterest);
  assert.ok(paid.governanceFunding > 0);
  assert.ok(paid.governanceFunding < current.governanceFunding);
  assert.ok(paid.exitDelayInterest > 0);
  const immediate = simulate(c, { policy: "harvest", exitLagDays: 0 });
  near(immediate.governanceFunding, 0);
});

test("yield-funded seven-day buffer covers the positive-carry three-day exits", () => {
  const r = simulate(c, { policy: "buffer" });
  near(r.governanceFunding, 0);
  assert.equal(r.unfundedExits, 0);
  assert.ok(r.averageReserve > 0);
  assert.ok(r.vaults.every((v) => v.exits.every((e) => e.reserve > 0)));
});

test("finite buffer does not promise unlimited settlement-time coverage", () => {
  const short = simulate(c, { policy: "buffer", exitLagDays: 3 });
  const long = simulate(c, { policy: "buffer", exitLagDays: 14 });
  assert.ok(long.governanceFunding > short.governanceFunding);
});

test("exit-cost buffer is required in addition to an interest-only budget", () => {
  const interestOnly = simulate(c, { policy: "buffer", loopRouteCost: 0.001 });
  const costed = simulate(c, {
    policy: "buffer",
    loopRouteCost: 0.001,
    exitCostReserveBps: 10,
  });
  assert.ok(interestOnly.governanceFunding > 0);
  near(costed.governanceFunding, 0);
  assert.ok(costed.averageReserve > interestOnly.averageReserve);
});

test("future harvests cannot prefund an early exit", () => {
  const r = simulate(c, {
    policy: "buffer",
    loopRouteCost: 0.001,
    exitCostReserveBps: 10,
    halfExitDay: 1,
  });
  assert.ok(r.governanceFunding > 0);
  assert.ok(r.vaults.every((v) => v.exits[0].funding > 0));
});

test("withdrawal model sells only the exiting slice's accrued yield", () => {
  const r = simulate(c, { policy: "withdrawal", recordDaily: true });
  near(r.governanceFunding, 0);
  assert.equal(r.reverseSwaps, 4);
  for (const v of r.vaults) {
    near(
      v.exits.reduce((n, e) => n + e.principalUnits, 0),
      v.initialUnits
    );
    assert.ok(v.exits.every((e) => e.paidUnits >= e.principalUnits));
    assert.ok(v.exits.every((e) => e.soldYieldUnits > 0));
    assert.equal(v.principal, 0);
  }
});

test("deferred repayment carries debt in borrowing headroom", () => {
  const r = simulate(c, {
    policy: "withdrawal",
    path: "bull",
    recordDaily: true,
  });
  for (const row of r.daily) {
    const v = r.vaults.find((v) => v.symbol === row.symbol);
    near(
      row.headroom,
      Math.max(0, row.collateral * row.price * v.ltv - row.mainDebt)
    );
  }
});

test("queued delay interest belongs to its exiting slice, not other holders", () => {
  const r = simulate(c, { policy: "withdrawal" });
  for (const v of r.vaults) {
    near(
      v.exitDelayInterest,
      v.exits.reduce((n, e) => n + e.delayInterest, 0)
    );
    for (const e of v.exits)
      near(e.debtAtSettlement - e.debtAtStart, e.delayInterest);
  }
});

test("full Main discount removes Main costs, not loop borrowing or losses", () => {
  const runs = POLICIES.map((policy) => simulate(c, { policy, discount: 1 }));
  for (const r of runs) {
    assert.equal(r.mainInterest, 0);
    near(r.governanceFunding, 0);
    near(r.userTokenReturnPct, runs[0].userTokenReturnPct);
    assert.ok(r.loopInterest > 0);
  }
  const bear = simulate(c, { policy: "buffer", path: "bear", discount: 1 });
  assert.equal(bear.mainInterest, 0);
  assert.ok(bear.governanceFunding > 0);
});

test("bear losses cannot be hidden as harvest or charged to principal", () => {
  for (const policy of POLICIES) {
    const r = simulate(c, { policy, path: "bear" });
    assert.equal(r.fees, 0);
    assert.equal(r.userTokenReturnPct, 0);
    assert.ok(r.governanceFunding > r.mainInterest);
    near(r.governanceFunding, r.minimumPrincipalSupport);
    assert.ok(r.vaults.every((v) => v.paidUnits === v.initialUnits));
  }
});

test("outage accrues debt with no services and retains the funding gap", () => {
  const r = simulate(c, { policy: "buffer", outage: true, recordDaily: true });
  const rows = r.daily.filter(
    (d) => d.day >= 21 && d.day <= 50 && d.symbol === "ETH"
  );
  assert.equal(rows.length, 30);
  assert.ok(rows.every((d) => d.offline));
  assert.ok(rows[29].mainDebt > rows[0].mainDebt);
  near(rows[29].reserve, rows[0].reserve);
});

test("100% fee leaves no fresh yield for user interest servicing", () => {
  const r = simulate(c, { policy: "buffer", fee: 1 });
  assert.equal(r.reverseSwaps, 0);
  assert.ok(r.governanceFunding > 0);
  near(r.userTokenReturnPct, 0);
});

test("conservation holds through two exits, route friction and every price path", () => {
  for (const path of PATHS)
    for (const policy of POLICIES) {
      const r = simulate(c, { path, policy, loopRouteCost: 0.001 });
      assert.ok(r.conservationError < 1e-6);
      for (const v of r.vaults) {
        assert.equal(v.debt, 0);
        assert.equal(v.equity, 0);
        assert.equal(v.collateral, 0);
        assert.ok(v.paidUnits >= v.initialUnits);
      }
    }
});

test("TVL scales economic amounts, not native capacity", () => {
  const small = simulate(c, { policy: "buffer" });
  const large = simulate(c, { policy: "buffer", tvl: 1000000 });
  near(large.fees, small.fees * 10);
  near(large.userTokenReturnPct, small.userTokenReturnPct);
  assert.equal(small.capacityBreaches.marketMint, false);
  assert.equal(large.capacityBreaches.marketMint, true);
});

test("results distinguish token yield from market price appreciation", () => {
  assert.deepEqual(market(90, "bull", 0.04).factors, [2, 1.6]);
  const r = simulate(c, { path: "bull", policy: "withdrawal" });
  assert.ok(r.userTokenReturnPct < 10);
  near(
    r.userGainAtInitialPrices,
    r.vaults.reduce(
      (n, v) => n + (v.paidUnits - v.initialUnits) * v.initialPrice,
      0
    )
  );
});

test("execution-cost sensitivity is explicit rather than assumed native gas pricing", () => {
  const r = simulate(c, { policy: "buffer", gasPerReverse: 0.1 });
  near(r.estimatedExtraExecutionCost, r.reverseSwaps * 0.1);
});

const snapshotFile = process.env.PROPELLER_MARKET_SNAPSHOT;
test(
  "fresh pinned inputs cover all six TVLs and the complete comparison",
  { skip: !snapshotFile },
  () => {
    const snapshot = JSON.parse(readFileSync(snapshotFile));
    const result = runComparison(snapshot);
    assert.equal(result.scenarios.length, 720);
    assert.equal(result.sensitivities.length, 460);
    assert.equal(result.calibration.borrowApr, capacity(snapshot).borrowApr);
    for (const r of [...result.scenarios, ...result.sensitivities]) {
      assert.ok(r.conservationError < r.tvl * 1e-10);
      assert.ok(r.vaults.every((v) => v.paidUnits + 1e-12 >= v.initialUnits));
    }
  }
);
