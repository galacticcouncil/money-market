import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  TVLS,
  prices,
  capacity,
  envelope,
  loadMath,
  poolQuote,
  hsmCapacity,
  hsmSpillover,
  run,
  primeGapStress,
} from "./pressure-model.mjs";
const file = process.env.PROPELLER_MARKET_SNAPSHOT;
const snapshot = file ? JSON.parse(readFileSync(file)) : null;
const c = {
  leverage: 1 / (1 - 0.88 / 1.05),
  ltv: [0.75, 0.8],
  price: [3000, 60000],
  borrowApr: 0.044,
  marketMintRoom: 1e6,
  primeSupplyRoom: 6e6,
  ethSupplyRoom: 8e6,
  btcSupplyRoom: 1.5e6,
  primeIsolationRoom: 4e6,
  primeAvailable: 9e6,
};
test("six requested TVLs and 90-day price paths", () => {
  assert.deepEqual(
    TVLS,
    [100000, 500000, 1000000, 10000000, 50000000, 100000000]
  );
  assert.deepEqual(prices(90, "bull"), [2, 1.6]);
  assert.ok(Math.abs(prices(90, "bear")[0] - 0.3) < 1e-12);
  assert.deepEqual(prices(10, "seesaw"), [1.4, 1.4]);
  assert.ok(Math.abs(prices(19, "seesaw")[0] - 0.68) < 1e-12);
});
test("debt identities and modeled funding are explicit", () => {
  const r = envelope(100000, "bull", c);
  assert.equal(r.initialEquity, 77500);
  assert.ok(Math.abs(r.initialGross - 478676.470588) < 1e-5);
  assert.equal(r.daily.length, 90);
  for (const d of r.daily)
    assert.ok(Math.abs(d.equity + d.loopDebt - d.gross) < 1e-7);
  assert.equal(r.externalFunding, r.mainInterest + r.negativeCarry);
  assert.ok(Math.abs(r.compounded + r.fees - r.harvest) < 1e-7);
});
test("Main discount never subsidizes loop interest; bear still needs loss funding", () => {
  const r = envelope(100000, "bear", c, { discount: 1 });
  assert.equal(r.mainInterest, 0);
  assert.ok(r.negativeCarry > 0);
  assert.ok(r.externalFunding > 0);
});

test("PRIME gap losses separate Main funding from loop bad debt", () => {
  const mild = primeGapStress(100000, c, 0.05);
  assert.ok(mild.healthFactor < 1);
  assert.equal(mild.loopBadDebt, 0);
  const severe = primeGapStress(100000, c, 0.25);
  assert.ok(severe.loopBadDebt > 0);
  assert.equal(severe.mainBackingDeficit, 77500);
  assert.ok(
    Math.abs(
      severe.protocolFundingBeforeFees - 100000 * 0.775 * c.leverage * 0.25
    ) < 1e-7
  );
});
test("outage defers harvest and resizing, without hiding accrued interest", () => {
  const r = envelope(100000, "bull", c, { outage: true });
  for (const d of r.daily.slice(20, 50)) {
    assert.equal(d.sellHollar, 0);
    assert.equal(d.buyHollar, 0);
    assert.equal(d.harvest, 0);
  }
  assert.ok(r.daily[49].unservicedMainInterest > 0);
  assert.ok(r.daily[50].harvest > r.daily[19].harvest);
});
test("TVL scaling is linear only before capacity gates", () => {
  const small = envelope(100000, "bull", c),
    large = envelope(1000000, "bull", c);
  assert.ok(Math.abs(large.sellHollar / small.sellHollar - 10) < 1e-9);
  assert.equal(small.breaches.marketMint, false);
  assert.equal(large.breaches.marketMint, true);
});
test("partial and final exits expose both HOLLAR and PRIME liquidity demand", () => {
  const r = envelope(100000, "bull", c, { exitFraction: 0.5 });
  assert.ok(r.daily[59].buyHollar > 0);
  assert.equal(r.fullExitHollarDemand, r.finalGross);
  assert.ok(r.primeExitLiquidityRatio > 0 && r.primeExitLiquidityRatio < 1);
});
test(
  "pinned snapshot quotes, HSM limits and capacity gates",
  { skip: !snapshot },
  () => {
    const math = loadMath(process.env.HYDRATION_MATH_ROOT),
      p = snapshot.pools[143];
    const out = poolQuote(math.stable, p, 222, 43, 1000n * 10n ** 18n);
    assert.ok(
      out > 0n && out < BigInt(p.reserves.find((r) => r.id === 43).balance)
    );
    for (const h of hsmCapacity(snapshot, math)) {
      assert.ok(Math.abs(h.limitPerBlock - h.imbalance * h.buybackRate) < 1e-8);
      assert.ok(h.availableBuybackPerBlock <= h.limitPerBlock);
    }
    const spill = hsmSpillover(snapshot, math, 1e6);
    assert.ok(spill.reserveCoverage < 1);
    assert.ok(
      spill.reserveCoverage * 1e6 <= capacity(snapshot).hsmBurnCapacity
    );
    const emptyBucket = structuredClone(snapshot);
    emptyBucket.facilitators.find(
      (f) => f.label === "HOLLAR Stability Module"
    ).bucketLevel = "0";
    const noBurn = hsmSpillover(emptyBucket, math, 1e6);
    assert.equal(noBurn.priceEligibleBuybackPerBlock, 0);
    assert.equal(noBurn.reserveCoverage, 0);
    assert.ok(
      spill.rateCeilingPerBlock >
        hsmCapacity(snapshot, math).reduce((n, h) => n + h.limitPerBlock, 0)
    );
    const r = run(snapshot, math);
    assert.equal(r.scenarios.length, 108);
    assert.equal(r.spillovers.length, 18);
    assert.equal(r.primeGapStress.length, 24);
    assert.ok(r.entries.find((e) => e.tvl === 500000).exceedsMarketMint);
    assert.ok(r.noRefillEntryAtOnePercent >= 0);
    // A newer snapshot can have no entry satisfying this oracle floor. Check
    // the quote itself, rather than assuming the old positive capacity persists.
    const probe =
      r.noRefillEntryAtOnePercent === 0
        ? 10n ** 18n
        : BigInt(Math.floor(r.noRefillEntryAtOnePercent * 0.9 * 1e6)) *
          10n ** 12n;
    const probeOut = poolQuote(math.stable, p, 222, 43, probe);
    const satisfiesFloor =
      probeOut * BigInt(snapshot.markets.PRIME.price) * 10n ** 12n * 100n >=
      probe * 10n ** 8n * 99n;
    assert.equal(satisfiesFloor, r.noRefillEntryAtOnePercent > 0);
    assert.equal(capacity(snapshot).leverage, c.leverage);
  }
);
