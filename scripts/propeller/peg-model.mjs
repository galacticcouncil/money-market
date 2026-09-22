// Downside peg stress and liquidity sizing, not a global HOLLAR price forecast.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import {
  TVLS,
  capacity,
  envelope,
  loadMath,
  poolQuote,
  usd,
} from "./pressure-model.mjs";

const H = 222;
const ONE = 10n ** 18n;
const min = (a, b) => (a < b ? a : b);
const ceilDiv = (a, b) => (a + b - 1n) / b;
export const units = (value, decimals = 18) =>
  BigInt(Math.round(value * 1e6)) * 10n ** BigInt(decimals - 6);
const reserve = (pool, id) => pool.reserves.find((r) => r.id === id);
const amount = (pool, id) => BigInt(reserve(pool, id).balance);
function change(pool, id, delta) {
  const next = amount(pool, id) + delta;
  assert.ok(next >= 0n, "negative pool inventory");
  reserve(pool, id).balance = next.toString();
}
function sell(stable, pool, id, hollar) {
  const out = poolQuote(stable, pool, H, id, hollar);
  change(pool, H, hollar);
  change(pool, id, -out);
  return out;
}
export function price(stable, pool, id, collateralPrice = 1) {
  return (
    usd(poolQuote(stable, pool, H, id, ONE), reserve(pool, id).info.decimals) *
    collateralPrice
  );
}
export function afterSale(stable, pool, id, hollar, collateralPrice = 1) {
  const p = structuredClone(pool);
  const out = sell(stable, p, id, units(hollar));
  return {
    averagePrice: hollar
      ? (usd(out, reserve(p, id).info.decimals) * collateralPrice) / hollar
      : price(stable, p, id, collateralPrice),
    endPrice: price(stable, p, id, collateralPrice),
  };
}
export function saleCapacity(stable, pool, id, floor, collateralPrice = 1) {
  let low = 0,
    high = 1e10;
  if (price(stable, pool, id, collateralPrice) < floor) return 0;
  for (let i = 0; i < 65; i++) {
    const mid = (low + high) / 2;
    if (afterSale(stable, pool, id, mid, collateralPrice).endPrice >= floor)
      low = mid;
    else high = mid;
  }
  return low;
}

// Hypothetical external LP funding at the stored relative peg, NOT scaling an
// already imbalanced pool. Dollar totals include HOLLAR plus the other asset.
export function balancedPool(template, id, total, collateralPrice = 1) {
  const p = structuredClone(template);
  assert.equal(p.reserves.length, 2);
  reserve(p, H).balance = units(total / 2).toString();
  reserve(p, id).balance = units(
    total / 2 / collateralPrice,
    reserve(p, id).info.decimals
  ).toString();
  return p;
}
export function requiredPool(
  stable,
  template,
  id,
  flow,
  floor,
  collateralPrice = 1
) {
  if (flow === 0) return 0;
  let low = 1,
    high = flow * 100;
  const succeeds = (total) =>
    afterSale(
      stable,
      balancedPool(template, id, total, collateralPrice),
      id,
      flow,
      collateralPrice
    ).endPrice >= floor;
  assert.ok(succeeds(high), "floor unattainable at search upper bound");
  for (let i = 0; i < 60; i++) {
    const mid = (low + high) / 2;
    if (succeeds(mid)) high = mid;
    else low = mid;
  }
  return high;
}
export function requiredTopUp(stable, template, id, flow, floor) {
  const succeeds = (total) => {
    const p = structuredClone(template);
    change(p, H, units(total / 2));
    change(p, id, units(total / 2, reserve(p, id).info.decimals));
    return afterSale(stable, p, id, flow).endPrice >= floor;
  };
  if (succeeds(0)) return 0;
  let low = 0,
    high = flow * 100;
  assert.ok(succeeds(high));
  for (let i = 0; i < 60; i++) {
    const mid = (low + high) / 2;
    if (succeeds(mid)) high = mid;
    else low = mid;
  }
  return high;
}

export function stateFrom(snapshot) {
  const rows = snapshot.hsm.collaterals.map((c) => {
    const pool = structuredClone(snapshot.pools[c.config.poolId]);
    assert.equal(
      pool.pegs,
      null,
      "dynamic HSM pegs need explicit normalization"
    );
    assert.equal(pool.info.initialAmplification, pool.info.finalAmplification);
    return {
      id: c.id,
      config: c.config,
      decimals: c.info.decimals,
      pool,
      holding: BigInt(c.balance),
      initialH: amount(pool, H),
      initialCollateral: amount(pool, c.id) + BigInt(c.balance),
      externalSold: 0n,
      externalReceived: 0n,
      burned: 0n,
      profit: 0n,
      donated: 0n,
    };
  });
  const burn = BigInt(
    snapshot.facilitators.find((f) => f.label === "HOLLAR Stability Module")
      .bucketLevel
  );
  return {
    rows,
    burn,
    initialBurn: burn,
    minArb: BigInt(snapshot.hsm.minArbitrageAmount || ONE),
    flashLimit: BigInt(
      snapshot.facilitators.find((f) => f.label === "HOLLAR FlashMinter")
        .bucketCapacity
    ),
  };
}
export function inject(state, math, hollar, weights = [0.5, 0.5]) {
  assert.equal(weights.length, state.rows.length);
  assert.ok(Math.abs(weights.reduce((a, b) => a + b, 0) - 1) < 1e-12);
  let left = units(hollar);
  for (let i = 0; i < state.rows.length; i++) {
    const r = state.rows[i];
    const q = i === state.rows.length - 1 ? left : units(hollar * weights[i]);
    left -= q;
    r.externalReceived += sell(math.stable, r.pool, r.id, q);
    r.externalSold += q;
  }
}

// Follow runtime calculate_ideal_trade_size and its exact-output BUY quote.
// A too-large candidate reverts when burning: the OCW does not clamp to the
// remaining facilitator bucket. This is deliberately not an idealized buyer.
export function candidate(state, math, r) {
  const peg = JSON.stringify([
    ONE.toString(),
    (10n ** BigInt(r.decimals)).toString(),
  ]);
  const imbalance = math.hsm.calculate_imbalance(
    amount(r.pool, H).toString(),
    peg,
    amount(r.pool, r.id).toString()
  );
  let q = BigInt(
    math.hsm.calculate_buyback_limit(
      imbalance,
      String(r.config.buybackRate / 1e9)
    )
  );
  if (q <= state.minArb || r.holding === 0n) return null;
  const quote = (size) => {
    const cost = poolQuote(math.stable, r.pool, r.id, H, size, true);
    const payment = ceilDiv(
      cost * 1000000n,
      BigInt(1000000 - r.config.buyBackFee)
    );
    return { q: size, cost, payment };
  };
  let trade = quote(q);
  const max = BigInt(r.config.maxBuyPriceCoefficient);
  const feeDen = BigInt(1000000 - r.config.buyBackFee);
  const permitted = (t) =>
    t.cost * 1000000n * ONE * ONE <=
    t.q * feeDen * max * 10n ** BigInt(r.decimals);
  if (!permitted(trade)) return null;
  q = min(q, (r.holding * q * feeDen) / (trade.cost * 1000000n));
  if (q <= state.minArb || q > state.burn || q > state.flashLimit) return null;
  trade = quote(q);
  if (trade.payment > r.holding || !permitted(trade)) return null;
  return trade;
}
export function execute(state, r, trade) {
  change(r.pool, H, -trade.q);
  change(r.pool, r.id, trade.cost);
  r.holding -= trade.payment;
  r.profit += trade.payment - trade.cost;
  r.burned += trade.q;
  state.burn -= trade.q;
  assert.ok(r.holding >= 0n && state.burn >= 0n);
}
export function conservation(state) {
  let burned = 0n;
  for (const r of state.rows) {
    assert.equal(r.initialH + r.externalSold, amount(r.pool, H) + r.burned);
    assert.equal(
      r.initialCollateral + r.donated,
      amount(r.pool, r.id) + r.holding + r.externalReceived + r.profit
    );
    burned += r.burned;
  }
  assert.equal(state.initialBurn, state.burn + burned);
}

// Exact per-block swaps, one collateral on each alternating block as in the
// OCW. Inactive intervals are skipped only when no pool state can change.
// Daily arrivals are bursts at day start; no assumed organic buyers/refills.
export function simulate(
  snapshot,
  math,
  {
    sales = [0],
    days = 90,
    outageDays = 0,
    weights = [0.5, 0.5],
    reserveFraction = 1,
    donate = 0,
    hypotheticalBurn = 0,
    serviceEvery = 1,
  } = {}
) {
  const state = stateFrom(snapshot);
  for (const r of state.rows) {
    const original = r.holding;
    r.holding =
      (original * BigInt(Math.round(reserveFraction * 1e6))) / 1000000n +
      units(donate / state.rows.length, r.decimals);
    r.donated = r.holding - original;
  }
  state.burn += units(hypotheticalBurn);
  state.initialBurn = state.burn;
  const seconds = snapshot.observedBlockSeconds;
  assert.ok(seconds > 0, "snapshot block cadence required");
  const blocksPerDay = Math.round(86400 / seconds);
  let burned = 0,
    spent = 0,
    minimum = 1,
    swaps = 0,
    firstBackTo99Hours = null;
  const below99 = { seconds: 0 },
    daily = [];
  let marks = state.rows.map((r) => price(math.stable, r.pool, r.id));
  function advance(n) {
    if (Math.min(...marks) < 0.99) below99.seconds += n * seconds;
  }
  for (let day = 0; day < days; day++) {
    inject(state, math, sales[day] || 0, weights);
    marks = state.rows.map((r) => price(math.stable, r.pool, r.id));
    minimum = Math.min(minimum, ...marks);
    if (day === 0 && Math.min(...marks) >= 0.99) firstBackTo99Hours = 0;
    let cached = state.rows.map((r) => candidate(state, math, r));
    let block = day * blocksPerDay;
    const end = (day + 1) * blocksPerDay;
    const outageEnd = Math.ceil(outageDays * blocksPerDay);
    if (block < outageEnd) {
      const skip = Math.min(end, outageEnd) - block;
      advance(skip);
      block += skip;
    }
    while (block < end) {
      if (!cached.some(Boolean)) {
        advance(end - block);
        break;
      }
      const index = block % state.rows.length;
      // serviceEvery=2 makes each collateral eligible every other rotation.
      const available =
        Math.floor(block / state.rows.length) % serviceEvery === 0;
      const t = cached[index],
        r = state.rows[index];
      advance(1);
      if (available && t) {
        if (t.q > state.burn) cached[index] = null;
        else {
          execute(state, r, t);
          burned += usd(t.q);
          spent += usd(t.payment, r.decimals);
          swaps++;
          marks[index] = price(math.stable, r.pool, r.id);
          if (firstBackTo99Hours === null && Math.min(...marks) >= 0.99)
            firstBackTo99Hours = ((block + 1) * seconds) / 3600;
          cached[index] = candidate(state, math, r);
        }
      }
      block++;
    }
    conservation(state);
    daily.push({
      day: day + 1,
      sold: sales[day] || 0,
      prices: marks.slice(),
      burned,
      spent,
      hsmRemaining: state.rows.reduce(
        (sum, r) => sum + usd(r.holding, r.decimals),
        0
      ),
      burnRemaining: usd(state.burn),
    });
  }
  return {
    minimumPrice: minimum,
    finalPrice: Math.min(...marks),
    hoursBelow99: below99.seconds / 3600,
    firstBackTo99Hours,
    burned,
    spent,
    swaps,
    daily,
    conservation: true,
    hsmRemaining: daily.at(-1).hsmRemaining,
    burnRemaining: usd(state.burn),
  };
}

export function sizing(snapshot, math) {
  const c = capacity(snapshot),
    prototype = snapshot.pools[110];
  const prime = snapshot.pools[143];
  const peg =
    prime.pegs.current[prime.reserves.findIndex((r) => r.id === 43)].map(
      BigInt
    );
  const primePrice = Number(peg[0]) / Number(peg[1]);
  const rows = [];
  for (const tvl of TVLS) {
    const gross = ((tvl * (c.ltv[0] + c.ltv[1])) / 2) * c.leverage;
    for (const spill of [0.1, 0.25, 1]) {
      const pressure = gross * spill;
      // Equal routing across two identical balanced pools. Solve each side so
      // the $1 terminal probe is not diluted by combining distinct pools.
      const pools = Object.fromEntries(
        [0.995, 0.99, 0.98].map((floor) => [
          floor,
          2 * requiredPool(math.stable, prototype, 1003, pressure / 2, floor),
        ])
      );
      const inventory = pressure / 2;
      const probePool = balancedPool(prototype, 1003, pools[0.99] / 2);
      sell(math.stable, probePool, 1003, units(inventory));
      const imbalance =
        (usd(amount(probePool, H)) - usd(amount(probePool, 1003), 6)) / 2;
      const rate =
        snapshot.hsm.collaterals.find((h) => h.id === 1003).config.buybackRate /
        1e9;
      const bandRatePerDay =
        (imbalance * rate * 86400) / snapshot.observedBlockSeconds;
      rows.push({
        tvl,
        spill,
        grossHollar: gross,
        sellPressure: pressure,
        pools,
        stableSideAt99: pools[0.99] / 2,
        hsmParReserve: pressure,
        hsmReserveWith20pctMargin: pressure * 1.2,
        idealRotatingOcwBuybackAt99PerDay: bandRatePerDay,
        additionalBalancedLpAt99: snapshot.hsm.collaterals.reduce(
          (sum, h) =>
            sum +
            requiredTopUp(
              math.stable,
              snapshot.pools[h.config.poolId],
              h.id,
              pressure / 2,
              0.99
            ),
          0
        ),
        supportedTvlByExistingHsm:
          Math.min(c.hsmCollateral, c.hsmBurnCapacity) /
          ((gross / tvl) * spill),
      });
    }
  }
  const primeSizing = TVLS.map((tvl) => {
    const flow = ((tvl * (c.ltv[0] + c.ltv[1])) / 2) * c.leverage;
    const total = requiredPool(math.stable, prime, 43, flow, 0.99, primePrice);
    return {
      tvl,
      flow,
      balancedTotalAt99: total,
      primeSideValue: total / 2,
      primeTokens: total / 2 / primePrice,
      reference: "stored PRIME peg, not executable oracle guarantee",
    };
  });
  return { rows, primeSizing };
}

export function run(snapshot, math) {
  const c = capacity(snapshot);
  const currentPools = snapshot.hsm.collaterals.map((h) => {
    const p = snapshot.pools[h.config.poolId];
    return {
      id: h.config.poolId,
      collateralId: h.id,
      hollar: usd(amount(p, H)),
      collateral: usd(amount(p, h.id), h.info.decimals),
      oneHollarPrice: price(math.stable, p, h.id),
      saleCapacity: Object.fromEntries(
        [0.995, 0.99, 0.98].map((floor) => [
          floor,
          saleCapacity(math.stable, p, h.id, floor),
        ])
      ),
    };
  });
  const currentThroughput = [0.995, 0.99, 0.98].map((floor) => {
    let perBlock = 0;
    for (const h of snapshot.hsm.collaterals) {
      const p = structuredClone(snapshot.pools[h.config.poolId]);
      sell(
        math.stable,
        p,
        h.id,
        units(saleCapacity(math.stable, p, h.id, floor))
      );
      const imbalance =
        (usd(amount(p, H)) - usd(amount(p, h.id), h.info.decimals)) / 2;
      perBlock +=
        (imbalance * h.config.buybackRate) /
        1e9 /
        snapshot.hsm.collaterals.length;
    }
    return {
      floor,
      idealRotatingOcwPerDay:
        (perBlock * 86400) / snapshot.observedBlockSeconds,
    };
  });
  const scenarios = [];
  for (const tvl of TVLS)
    for (const spill of [0.1, 0.25, 1])
      for (const rampDays of [1, 7, 30]) {
        const pressure =
          ((tvl * (c.ltv[0] + c.ltv[1])) / 2) * c.leverage * spill;
        const result = simulate(snapshot, math, {
          sales: Array(rampDays).fill(pressure / rampDays),
        });
        scenarios.push({ tvl, spill, rampDays, ...result });
      }
  const marketPaths = [];
  for (const tvl of TVLS)
    for (const path of ["bull", "bear", "seesaw"]) {
      const e = envelope(tvl, path, c, { exitFraction: 0.5 });
      const sales = e.daily.map((d) => d.sellHollar * 0.25);
      sales[0] += e.initialGross * 0.25;
      marketPaths.push({
        tvl,
        path,
        spill: 0.25,
        grossOneWaySales: e.sellHollar,
        assumedStableSales: sales.reduce((a, b) => a + b, 0),
        ignoredReverseHollarBuys: e.buyHollar,
        ...simulate(snapshot, math, { sales }),
      });
    }
  const base = ((1e6 * (c.ltv[0] + c.ltv[1])) / 2) * c.leverage * 0.25;
  const sensitivities = [];
  for (const [name, opts] of Object.entries({
    zeroReserves: { reserveFraction: 0 },
    halfReserves: { reserveFraction: 0.5 },
    outage12h: { outageDays: 0.5 },
    outage3d: { outageDays: 3 },
    halfService: { serviceEvery: 2 },
    concentratedUSDT: { weights: [1, 0] },
    collateralDonationOnly: { donate: base },
    hypotheticalFundedBurnCapacity: { donate: base, hypotheticalBurn: base },
  }))
    sensitivities.push({
      name,
      pressure: base,
      ...simulate(snapshot, math, { sales: [base], ...opts }),
    });
  const runPressure = usd(snapshot.hollarTotalSupply) * 0.1;
  sensitivities.push({
    name: "tenPercentExistingSupplyRun",
    pressure: runPressure,
    ...simulate(snapshot, math, { sales: [runPressure] }),
  });
  const raised = structuredClone(snapshot);
  for (const f of raised.facilitators) f.bucketCapacity = units(1e9).toString();
  sensitivities.push({
    name: "raisedMintCapsOnly",
    pressure: base,
    ...simulate(raised, math, { sales: [base] }),
  });
  for (const rampDays of [7, 30])
    sensitivities.push({
      name: `hypotheticalFunded${rampDays}DayRamp`,
      pressure: base,
      ...simulate(snapshot, math, {
        sales: Array(rampDays).fill(base / rampDays),
        donate: base,
        hypotheticalBurn: base,
      }),
    });
  const lpExit = structuredClone(snapshot);
  for (const h of lpExit.hsm.collaterals)
    for (const r of lpExit.pools[h.config.poolId].reserves)
      r.balance = (BigInt(r.balance) / 2n).toString();
  sensitivities.push({
    name: "halfPoolLiquidityWithdrawn",
    pressure: base,
    ...simulate(lpExit, math, { sales: [base] }),
  });
  return {
    block: snapshot.block,
    hash: snapshot.hash,
    dependencies: math.dependencies,
    assumptions: {
      days: 90,
      blocksPerDay: Math.round(86400 / snapshot.observedBlockSeconds),
      blockSeconds: snapshot.observedBlockSeconds,
      routing: "50/50 unless stated",
      arrivals: "daily bursts; rampDays=1 is instantaneous full entry",
      service:
        "one collateral per block, alternating, all profitable OCW candidates included",
      HsmReturn: "aTokens at nominal $1, not guaranteed cash USD",
      demand:
        "no independent buyers, borrowing repayments, HSM mints or LP refill",
      hypotheticalBurn:
        "analytical counterfactual, not a deployable governance parameter",
    },
    current: {
      supply: usd(snapshot.hollarTotalSupply),
      hsmCollateral: c.hsmCollateral,
      hsmBurnCapacity: c.hsmBurnCapacity,
      hsmMintRoom: c.hsmMintRoom,
      marketMintRoom: c.marketMintRoom,
      currentPools,
      currentThroughput,
    },
    ...sizing(snapshot, math),
    scenarios,
    marketPaths,
    sensitivities,
  };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const file = process.argv[2],
    output = process.argv[3] || "/tmp/propeller-peg-results.json";
  if (!file) throw new Error("usage: peg-model.mjs SNAPSHOT [OUTPUT]");
  const raw = readFileSync(file);
  const result = run(
    JSON.parse(raw),
    loadMath(process.env.HYDRATION_MATH_ROOT)
  );
  result.snapshotSha256 = createHash("sha256").update(raw).digest("hex");
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
  console.log(output, result.current);
  console.table(
    result.rows
      .filter((r) => r.spill === 0.25)
      .map((r) => ({
        tvl: r.tvl,
        pressure: r.sellPressure,
        poolTVL: r.pools[0.99],
        HSM: r.hsmParReserve,
      }))
  );
  console.table(
    result.scenarios
      .filter((r) => r.spill === 0.25)
      .map((r) => ({
        tvl: r.tvl,
        ramp: r.rampDays,
        min: r.minimumPrice,
        final: r.finalPrice,
        burn: r.burned,
        spent: r.spent,
        hoursBelow99: r.hoursBelow99,
      }))
  );
}
