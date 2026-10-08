// Coupled pool/inventory model. External settlement is a bounded assumption,
// not an assertion that an issuer/bridge/market maker has committed capacity.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { capacity, loadMath, poolQuote, usd } from "./pressure-model.mjs";
import { units, stateFrom, candidate, execute } from "./peg-model.mjs";

const H = 222,
  PRIME = 43,
  USD = "USD";
const min = (a, b) => (a < b ? a : b);
const abs = (x) => (x < 0n ? -x : x);
const get = (object, key) => object[key] || 0n;
function add(object, key, value) {
  object[key] = get(object, key) + value;
  assert.ok(object[key] >= 0n, `negative inventory: ${key}`);
}
const reserve = (pool, id) => pool.reserves.find((r) => r.id === id);
const balance = (pool, id) => BigInt(reserve(pool, id).balance);
function change(pool, id, delta) {
  const value = balance(pool, id) + delta;
  assert.ok(value >= 0n, "negative AMM inventory");
  reserve(pool, id).balance = value.toString();
}
function swap(math, pool, assetIn, assetOut, input) {
  const output = poolQuote(math.stable, pool, assetIn, assetOut, input);
  change(pool, assetIn, input);
  change(pool, assetOut, -output);
  return output;
}
function buy(math, pool, assetIn, assetOut, output) {
  const input = poolQuote(math.stable, pool, assetIn, assetOut, output, true);
  change(pool, assetIn, input);
  change(pool, assetOut, -output);
  return input;
}

export const defaults = {
  days: 90,
  rampDays: 30,
  warmupHours: 24,
  tickSeconds: 300,
  arbEverySeconds: 300,
  arbEnabled: true,
  hsmEnabled: true,
  agentCapital: 500000,
  maxArbHollar: 25000,
  arbRiskBps: 25,
  gasUsd: 0.05,
  entryFloor: 0.99,
  exitFloor: 0.99,
  entryRateMultiplier: 2,
  poolScale: 1,
  primePoolScale: 1,
  primeDailyCapacity: 1000000,
  primeDelayHours: 6,
  primeRedemptionCash: 1000000,
  primeFairPrice: null,
  stableDailyCapacity: 2000000,
  stableDelayHours: 1,
  settlementFeeBps: 10,
  cashFraction: 1,
  hsmReserveFraction: 1,
  hsmDonation: 0,
  buyerCoverage: 0,
  buyerDailyCapacity: null,
  buyerPriceCeiling: 0.999,
  buyerMode: "hold",
  mintCapsRaised: true,
  arbOutage: null,
  hsmOutage: null,
  settlementOutage: null,
  lpWithdrawal: null,
  cashWithdrawal: null,
  entryOutage: null,
  buyerBudget: null,
};
const offline = (range, hour) => range && hour >= range[0] && hour < range[1];

export function createState(snapshot, math, options = {}) {
  const config = { ...defaults, ...options };
  for (const key of [
    "days",
    "rampDays",
    "tickSeconds",
    "arbEverySeconds",
    "entryRateMultiplier",
  ])
    assert.ok(config[key] > 0, `${key} must be positive`);
  assert.ok(config.tickSeconds <= config.arbEverySeconds);
  assert.ok(config.buyerCoverage >= 0 && config.agentCapital >= 0);
  const hsm = stateFrom(snapshot),
    pools = {};
  for (const id of [105, 110, 111, 143]) {
    pools[id] = structuredClone(snapshot.pools[id]);
    const scale = id === 143 ? config.primePoolScale : config.poolScale;
    assert.ok(scale > 0);
    for (const r of pools[id].reserves)
      r.balance = (
        (BigInt(r.balance) * BigInt(Math.round(scale * 1e6))) /
        1000000n
      ).toString();
  }
  for (const r of hsm.rows) {
    r.pool = pools[r.config.poolId];
    r.holding =
      (r.holding * BigInt(Math.round(config.hsmReserveFraction * 1e6))) /
        1000000n +
      units(config.hsmDonation / 2, 6);
  }
  const decimals = {},
    prices = { [H]: 1 };
  const routes = [];
  for (const [poolId, pool] of Object.entries(pools))
    for (const r of pool.reserves) {
      decimals[r.id] = r.info.decimals;
      if (r.id !== H) {
        prices[r.id] =
          r.id === PRIME
            ? config.primeFairPrice ??
              Number(snapshot.markets.PRIME.price) / 1e8
            : 1;
        routes.push({ poolId: Number(poolId), id: r.id, pool });
      }
    }
  const gross =
    options.grossHollar ??
    (options.tvl || 1000000) *
      0.5 *
      (capacity(snapshot).ltv[0] + capacity(snapshot).ltv[1]) *
      capacity(snapshot).leverage;
  const state = {
    snapshot,
    math,
    config,
    pools,
    routes,
    hsm,
    decimals,
    prices,
    gross,
    agent: { [USD]: units(config.agentCapital * 0.25, 6) },
    target: {},
    pending: [],
    buyerCash: units(config.buyerBudget ?? gross * config.buyerCoverage, 6),
    buyerH: 0n,
    strategyPrime: 0n,
    strategyH: 0n,
    debt: 0n,
    externalIn: {},
    externalOut: {},
    gas: 0n,
    mmCash: Object.fromEntries(
      snapshot.hsm.collaterals.map((c) => [
        c.id,
        (BigInt(c.underlying.cashAtAToken) *
          BigInt(Math.round(config.cashFraction * 1e6))) /
          1000000n,
      ])
    ),
    providerCash: units(config.primeRedemptionCash, 6),
    providerUsed: 0,
    stableUsed: 0,
    buyerUsed: 0,
    day: null,
    now: 0,
    startBlock: 0,
    primeSubscribed: 0,
    primeRedeemed: 0,
    stableWithdrawn: 0,
    stableSupplied: 0,
    marketMinted: 0n,
    marketBurned: 0n,
    externalDebtRepaid: 0n,
    hsmMinted: 0n,
    hsmBurned: 0n,
    arbCount: 0,
    arbH: 0,
    arbMarkProfit: 0,
    hsmBuyCount: 0,
    hsmMintCount: 0,
    settlementCount: 0,
    settlementBlockedCash: 0,
    guardCount: 0,
    entryH: 0n,
    exitH: 0n,
    maxPending: 0,
    baseline: null,
    stressApplied: new Set(),
    stressLog: [],
    exitShortfall: 0,
  };
  state.initialBuyerCash = state.buyerCash;
  for (const id of Object.keys(prices)
    .map(Number)
    .filter((id) => id !== H)) {
    const dollars = config.agentCapital * (id === PRIME ? 0.5 : 0.25 / 4);
    state.target[id] = units(dollars / prices[id], decimals[id]);
    state.agent[id] = state.target[id];
  }
  state.initialTotal = totals(state);
  state.initialBurn = state.hsm.burn;
  return state;
}
function value(state, id, quantity) {
  return usd(quantity, state.decimals[id]) * state.prices[id];
}
function oraclePrimeValue(state, quantity) {
  return (usd(quantity, 6) * Number(state.snapshot.markets.PRIME.price)) / 1e8;
}
function external(state, direction, id, amount) {
  add(direction === "in" ? state.externalIn : state.externalOut, id, amount);
}
export function totals(state) {
  const sum = {};
  for (const pool of Object.values(state.pools))
    for (const r of pool.reserves) add(sum, r.id, BigInt(r.balance));
  for (const r of state.hsm.rows) add(sum, r.id, r.holding + r.profit);
  for (const [id, q] of Object.entries(state.agent)) add(sum, id, q);
  for (const p of state.pending) add(sum, p.id, p.amount);
  add(sum, H, state.buyerH + state.strategyH);
  add(sum, PRIME, state.strategyPrime);
  add(sum, USD, state.buyerCash);
  return sum;
}
export function assertConservation(state) {
  const actual = totals(state);
  for (const id of new Set([
    ...Object.keys(actual),
    ...Object.keys(state.initialTotal),
  ])) {
    const minted = Number(id) === H ? state.marketMinted + state.hsmMinted : 0n;
    const burned =
      Number(id) === H
        ? state.marketBurned + state.externalDebtRepaid + state.hsmBurned
        : 0n;
    assert.equal(
      get(actual, id),
      get(state.initialTotal, id) +
        get(state.externalIn, id) -
        get(state.externalOut, id) +
        minted -
        burned,
      `token ledger ${id}`
    );
  }
  assert.equal(
    state.hsm.burn,
    state.initialBurn + state.hsmMinted - state.hsmBurned
  );
  assert.equal(state.debt, state.marketMinted - state.marketBurned);
  for (const q of Object.values(state.mmCash)) assert.ok(q >= 0n);
  assert.ok(state.providerCash >= 0n);
}
export function quoteMarks(state) {
  return state.routes.map((r) => ({
    poolId: r.poolId,
    id: r.id,
    bid:
      value(
        state,
        r.id,
        poolQuote(state.math.stable, r.pool, H, r.id, units(100))
      ) / 100,
    ask:
      value(
        state,
        r.id,
        poolQuote(state.math.stable, r.pool, r.id, H, units(100), true)
      ) / 100,
  }));
}

function bestSize(maximum, evaluate) {
  // Pool invariant math stays in the SDK; this search only chooses trade size.
  if (maximum <= 0) return null;
  let low = 0,
    high = maximum,
    best = null;
  for (let i = 0; i < 22; i++) {
    const a = (2 * low + high) / 3,
      b = (low + 2 * high) / 3;
    const qa = evaluate(a),
      qb = evaluate(b);
    if (qa && (!best || qa.profit > best.profit)) best = qa;
    if (qb && (!best || qb.profit > best.profit)) best = qb;
    if ((qa?.profit ?? -Infinity) > (qb?.profit ?? -Infinity)) high = b;
    else low = a;
  }
  const edge = evaluate(maximum);
  if (edge && (!best || edge.profit > best.profit)) best = edge;
  return best?.profit > 0 ? best : null;
}
export function arbitrage(state) {
  if (!state.config.arbEnabled || offline(state.config.arbOutage, state.now))
    return 0;
  let trades = 0;
  // Each round uses fresh quotes; a filled cycle changes both venues.
  for (let round = 0; round < 8; round++) {
    const marks = quoteMarks(state);
    let chosen = null;
    for (let i = 0; i < marks.length; i++)
      for (let j = 0; j < marks.length; j++) {
        const a = marks[i],
          b = marks[j];
        if (a.poolId === b.poolId) continue;
        const inventory = value(state, a.id, get(state.agent, a.id));
        if (
          inventory < 1 ||
          b.bid <= a.ask * (1 + state.config.arbRiskBps / 10000)
        )
          continue;
        const edge = b.bid - a.ask;
        if (!chosen || edge > chosen.edge)
          chosen = { a: state.routes[i], b: state.routes[j], edge, inventory };
      }
    if (!chosen) break;
    const { a, b, inventory } = chosen;
    const maximum = Math.min(
      state.config.maxArbHollar,
      (inventory /
        Math.max(
          0.01,
          marks.find((m) => m.poolId === a.poolId && m.id === a.id).ask
        )) *
        0.999,
      usd(balance(a.pool, H)) * 0.1
    );
    const trade = bestSize(maximum, (dollars) => {
      const q = units(dollars);
      if (q <= 0n) return null;
      const input = poolQuote(state.math.stable, a.pool, a.id, H, q, true);
      if (input > get(state.agent, a.id)) return null;
      const output = poolQuote(state.math.stable, b.pool, H, b.id, q);
      const inValue = value(state, a.id, input),
        outValue = value(state, b.id, output);
      return {
        q,
        input,
        output,
        profit:
          outValue -
          inValue -
          (inValue * state.config.arbRiskBps) / 10000 -
          state.config.gasUsd,
        markProfit: outValue - inValue,
      };
    });
    const gas = units(state.config.gasUsd, 6);
    if (!trade || get(state.agent, USD) < gas) break;
    const input = buy(state.math, a.pool, a.id, H, trade.q),
      output = swap(state.math, b.pool, H, b.id, trade.q);
    add(state.agent, a.id, -input);
    add(state.agent, b.id, output);
    add(state.agent, USD, -gas);
    external(state, "out", USD, gas);
    state.gas += gas;
    state.arbCount++;
    state.arbH += usd(trade.q);
    state.arbMarkProfit += trade.markProfit;
    trades++;
  }
  return trades;
}

function mintCandidate(state, r) {
  const collateral = balance(r.pool, r.id),
    hollar = balance(r.pool, H);
  const pegged = collateral * 10n ** 12n;
  if (hollar >= pegged) return null;
  const capacity = BigInt(
    state.snapshot.facilitators.find(
      (f) => f.label === "HOLLAR Stability Module"
    ).bucketCapacity
  );
  const free = capacity - state.hsm.burn;
  const holdingRoom = BigInt(r.config.maxInHolding) - r.holding;
  if (free <= 0n || holdingRoom <= 0n) return null;
  let high = min(min((pegged - hollar) / 2n, state.hsm.flashLimit), free);
  const fee = BigInt(1000000 + r.config.purchaseFee);
  if (
    poolQuote(state.math.stable, r.pool, H, r.id, units(1)) * 1000000n <=
    units(1, 6) * fee
  )
    return null;
  high = min(high, (holdingRoom * 10n ** 12n * 1000000n) / fee);
  let low = 0n;
  // Fee-inclusive 1-H terminal probe approximates the runtime's spot-price
  // predicate. Exact native mint-candidate parity is not asserted.
  for (let i = 0; i < 42; i++) {
    const mid = (low + high) / 2n;
    const p = structuredClone(r.pool);
    swap(state.math, p, H, r.id, mid);
    const after = poolQuote(state.math.stable, p, H, r.id, units(1));
    if (after * 1000000n > units(1, 6) * fee) low = mid;
    else high = mid;
  }
  if (low <= state.hsm.minArb) return null;
  const output = poolQuote(state.math.stable, r.pool, H, r.id, low);
  const payment =
    (low * fee + 10n ** 12n * 1000000n - 1n) / (10n ** 12n * 1000000n);
  return output > payment ? { q: low, output, payment } : null;
}
export function advanceHsm(state, seconds) {
  const blocks = Math.round(seconds / state.snapshot.observedBlockSeconds);
  if (!state.config.hsmEnabled || offline(state.config.hsmOutage, state.now)) {
    state.startBlock += blocks;
    return;
  }
  const plan = (r) => {
    const t = candidate(state.hsm, state.math, r);
    return t ? { direction: "buy", ...t } : mintCandidate(state, r);
  };
  const cached = state.hsm.rows.map(plan);
  for (let block = 0; block < blocks; block++) {
    if (!cached.some(Boolean)) break;
    const index = (state.startBlock + block) % state.hsm.rows.length;
    const r = state.hsm.rows[index],
      t = cached[index];
    if (!t) continue;
    if (t.direction === "buy") {
      if (t.q > state.hsm.burn) {
        cached[index] = null;
        continue;
      }
      execute(state.hsm, r, t);
      state.hsmBurned += t.q;
      state.hsmBuyCount++;
    } else {
      // The other collateral may have consumed shared mint room since caching.
      const fresh = mintCandidate(state, r);
      if (!fresh) {
        cached[index] = null;
        continue;
      }
      const out = swap(state.math, r.pool, H, r.id, fresh.q);
      r.holding += fresh.payment;
      r.profit += out - fresh.payment;
      state.hsm.burn += fresh.q;
      state.hsmMinted += fresh.q;
      state.hsmMintCount++;
    }
    cached[index] = plan(r);
  }
  state.startBlock += blocks;
}

function resetDay(state) {
  const day = Math.floor(state.now / 24);
  if (state.day !== day) {
    state.day = day;
    state.providerUsed = 0;
    state.stableUsed = 0;
    state.buyerUsed = 0;
  }
}
export function settle(state) {
  if (offline(state.config.settlementOutage, state.now)) return;
  const pending = [];
  for (const p of state.pending) {
    if (p.due <= state.now) {
      add(state.agent, p.id, p.amount);
      state.settlementCount++;
    } else pending.push(p);
  }
  state.pending = pending;
}
function schedule(state, id, amount, delay) {
  if (amount === 0n) return;
  state.pending.push({ id, amount, due: state.now + delay });
}
export function rebalanceInventory(state) {
  if (
    !state.config.arbEnabled ||
    offline(state.config.settlementOutage, state.now)
  )
    return;
  resetDay(state);
  const fee = state.config.settlementFeeBps / 10000;
  const inFlight = (id) =>
    state.pending
      .filter((p) => Number(p.id) === id)
      .reduce((a, p) => a + p.amount, 0n);
  // Sell excess before ordering shortages; unsettled proceeds cannot finance
  // another order. aToken redemptions consume actual shared underlying cash.
  for (const id of Object.keys(state.target).map(Number)) {
    const excess = get(state.agent, id) - state.target[id];
    if (excess <= 0n || value(state, id, excess) < 10) continue;
    const prime = id === PRIME;
    const capacityLeft = prime
      ? state.config.primeDailyCapacity - state.providerUsed
      : state.config.stableDailyCapacity - state.stableUsed;
    let q = min(
      excess,
      units(Math.max(0, capacityLeft) / state.prices[id], state.decimals[id])
    );
    const available = prime
      ? units(usd(state.providerCash, 6) / (1 - fee) / state.prices[id], 6)
      : state.mmCash[id];
    if (available !== undefined && q > available) {
      state.settlementBlockedCash++;
      q = available;
    }
    if (q <= 0n) continue;
    const receipt = units(value(state, id, q) * (1 - fee), 6);
    if (prime && receipt > state.providerCash) {
      state.settlementBlockedCash++;
      continue;
    }
    if (state.mmCash[id] !== undefined && q > state.mmCash[id]) {
      state.settlementBlockedCash++;
      continue;
    }
    add(state.agent, id, -q);
    external(state, "out", id, q);
    external(state, "in", USD, receipt);
    schedule(
      state,
      USD,
      receipt,
      prime ? state.config.primeDelayHours : state.config.stableDelayHours
    );
    if (prime) {
      state.providerCash -= receipt;
      state.providerUsed += value(state, id, q);
      state.primeRedeemed += value(state, id, q);
    } else {
      state.stableUsed += value(state, id, q);
      if (state.mmCash[id] !== undefined) {
        state.mmCash[id] -= q;
        state.stableWithdrawn += usd(q, 6);
      }
    }
  }
  for (const id of [
    PRIME,
    ...Object.keys(state.target)
      .map(Number)
      .filter((id) => id !== PRIME),
  ]) {
    const shortage = state.target[id] - get(state.agent, id) - inFlight(id);
    if (shortage <= 0n || value(state, id, shortage) < 10) continue;
    const prime = id === PRIME;
    const capacityLeft = prime
      ? state.config.primeDailyCapacity - state.providerUsed
      : state.config.stableDailyCapacity - state.stableUsed;
    const dollars = Math.min(
      value(state, id, shortage),
      Math.max(0, capacityLeft),
      usd(get(state.agent, USD), 6) / (1 + fee)
    );
    if (dollars < 10) continue;
    const q = units(dollars / state.prices[id], state.decimals[id]);
    const cost = units(value(state, id, q) * (1 + fee), 6);
    if (cost > get(state.agent, USD)) continue;
    add(state.agent, USD, -cost);
    external(state, "out", USD, cost);
    external(state, "in", id, q);
    schedule(
      state,
      id,
      q,
      prime ? state.config.primeDelayHours : state.config.stableDelayHours
    );
    if (prime) {
      state.providerUsed += value(state, id, q);
      state.primeSubscribed += value(state, id, q);
    } else {
      state.stableUsed += value(state, id, q);
      if (state.mmCash[id] !== undefined) {
        state.mmCash[id] += q;
        state.stableSupplied += usd(q, 6);
      }
    }
  }
}

export function externalBuy(state, seconds) {
  if (state.now < 0 || state.buyerCash <= 0n) return;
  resetDay(state);
  const daily =
    state.config.buyerDailyCapacity ??
    (state.gross / state.config.rampDays) * state.config.buyerCoverage;
  let budget = units(
    Math.min((daily * seconds) / 86400, Math.max(0, daily - state.buyerUsed)),
    6
  );
  budget = min(budget, state.buyerCash);
  if (budget < units(1, 6)) return;
  const eligible = state.routes.filter((r) => r.id === 1002 || r.id === 1003);
  const route = eligible.sort((a, b) =>
    Number(
      poolQuote(state.math.stable, a.pool, a.id, H, units(100), true) -
        poolQuote(state.math.stable, b.pool, b.id, H, units(100), true)
    )
  )[0];
  let low = 0n,
    high = units(
      usd(budget, 6) / Math.max(0.1, state.config.buyerPriceCeiling)
    );
  high = min(high, balance(route.pool, H) / 10n);
  for (let i = 0; i < 35; i++) {
    const mid = (low + high) / 2n;
    const cost = poolQuote(
      state.math.stable,
      route.pool,
      route.id,
      H,
      mid,
      true
    );
    if (
      cost <= budget &&
      usd(cost, 6) <= usd(mid) * state.config.buyerPriceCeiling
    )
      low = mid;
    else high = mid;
  }
  if (low < units(1)) return;
  const cost = buy(state.math, route.pool, route.id, H, low);
  state.buyerCash -= cost;
  state.buyerUsed += usd(cost, 6);
  external(state, "out", USD, cost);
  external(state, "in", route.id, cost);
  state.mmCash[route.id] += cost;
  state.stableSupplied += usd(cost, 6);
  if (state.config.buyerMode === "repay") {
    const market = BigInt(
      state.snapshot.facilitators.find((f) => f.label === "Hydration Market")
        .bucketLevel
    );
    const burn = min(low, market - state.externalDebtRepaid);
    state.externalDebtRepaid += burn;
    state.buyerH += low - burn;
  } else state.buyerH += low;
}

function maximumFill(maximum, satisfies) {
  if (satisfies(maximum)) return maximum;
  let low = 0n,
    high = maximum;
  for (let i = 0; i < 32; i++) {
    const mid = (low + high) / 2n;
    if (satisfies(mid)) low = mid;
    else high = mid;
  }
  return low;
}
export function tradeStrategy(state, target, seconds) {
  const pool = state.pools[143],
    desired = units(target);
  if (desired < state.debt && state.strategyH > 0n) {
    const repay = min(state.strategyH, state.debt - desired);
    state.strategyH -= repay;
    state.debt -= repay;
    state.marketBurned += repay;
  }
  const budget = units(
    (((state.gross / state.config.rampDays) * seconds) / 86400) *
      state.config.entryRateMultiplier
  );
  if (desired > state.debt) {
    if (offline(state.config.entryOutage, state.now)) return;
    let pending = desired - state.debt;
    state.maxPending = Math.max(state.maxPending, usd(pending));
    if (!state.config.mintCapsRaised) {
      const f = state.snapshot.facilitators.find(
        (f) => f.label === "Hydration Market"
      );
      pending = min(
        pending,
        BigInt(f.bucketCapacity) -
          BigInt(f.bucketLevel) -
          state.debt +
          state.externalDebtRepaid
      );
    }
    if (pending <= 0n) return;
    const q = maximumFill(
      min(pending, budget),
      (q) =>
        q === 0n ||
        oraclePrimeValue(
          state,
          poolQuote(state.math.stable, pool, H, PRIME, q)
        ) >=
          usd(q) * state.config.entryFloor
    );
    if (q < units(1)) {
      state.guardCount++;
      return;
    }
    const out = swap(state.math, pool, H, PRIME, q);
    state.strategyPrime += out;
    state.debt += q;
    state.marketMinted += q;
    state.entryH += q;
  } else if (desired < state.debt && state.strategyPrime > 0n) {
    const dollars = Math.min(usd(state.debt - desired), usd(budget));
    const oracle = Number(state.snapshot.markets.PRIME.price) / 1e8;
    const q = maximumFill(
      min(state.strategyPrime, units(dollars / oracle, 6)),
      (q) =>
        q === 0n ||
        usd(poolQuote(state.math.stable, pool, PRIME, H, q)) >=
          oraclePrimeValue(state, q) * state.config.exitFloor
    );
    if (q < units(1, 6)) {
      state.guardCount++;
      return;
    }
    const out = swap(state.math, pool, PRIME, H, q),
      repay = min(out, state.debt - desired);
    state.strategyPrime -= q;
    state.strategyH += out - repay;
    state.debt -= repay;
    state.marketBurned += repay;
    state.exitH += out;
  }
}

export function applyStress(state) {
  const lp = state.config.lpWithdrawal;
  if (lp && state.now >= lp.hour && !state.stressApplied.has("lp")) {
    assert.ok(lp.fraction >= 0 && lp.fraction < 1);
    const removed = {};
    for (const id of lp.pools ?? [105, 110, 111, 143])
      for (const r of state.pools[id].reserves) {
        const q =
          (BigInt(r.balance) * BigInt(Math.round(lp.fraction * 1e6))) /
          1000000n;
        change(state.pools[id], r.id, -q);
        external(state, "out", r.id, q);
        add(removed, r.id, q);
      }
    state.stressLog.push({
      kind: "lpWithdrawal",
      hour: state.now,
      fraction: lp.fraction,
      amounts: Object.fromEntries(
        Object.entries(removed).map(([id, q]) => [
          id,
          usd(q, state.decimals[id]),
        ])
      ),
    });
    state.stressApplied.add("lp");
  }
  const cash = state.config.cashWithdrawal;
  if (cash && state.now >= cash.hour && !state.stressApplied.has("cash")) {
    assert.ok(cash.fraction >= 0 && cash.fraction <= 1);
    for (const id of Object.keys(state.mmCash))
      state.mmCash[id] =
        (state.mmCash[id] * BigInt(Math.round((1 - cash.fraction) * 1e6))) /
        1000000n;
    state.stressLog.push({
      kind: "outsideLenderCashWithdrawal",
      hour: state.now,
      fraction: cash.fraction,
    });
    state.stressApplied.add("cash");
  }
}

function targetAt(state, hour, path) {
  if (hour < 0) return 0;
  if (path) return path[Math.min(path.length - 1, Math.floor(hour / 24))];
  return (
    state.gross *
    Math.min(
      1,
      (hour + state.config.tickSeconds / 3600) / (state.config.rampDays * 24)
    )
  );
}
export function simulate(snapshot, math, options = {}) {
  const state = createState(snapshot, math, options),
    cfg = state.config;
  let minStable = Infinity,
    minPrime = Infinity,
    maxStable = 0,
    maxSpread = 0,
    hoursBelow99 = 0,
    completeHour = null;
  let peakDebt = 0,
    maxUnwindShortfall = 0,
    underTargetHollarHours = 0,
    overTargetHollarHours = 0;
  const daily = [];
  const tickHours = cfg.tickSeconds / 3600;
  const warmTicks = Math.round(cfg.warmupHours / tickHours),
    runTicks = Math.round((cfg.days * 24) / tickHours);
  let nextArb = -cfg.warmupHours;
  for (let step = -warmTicks; step < runTicks; step++) {
    state.now = step * tickHours;
    resetDay(state);
    settle(state);
    applyStress(state);
    if (step === 0) {
      state.baseline = {
        hsmBurned: usd(state.hsmBurned),
        hsmMinted: usd(state.hsmMinted),
        marks: quoteMarks(state),
        hsmHolding: state.hsm.rows.reduce((s, r) => s + usd(r.holding, 6), 0),
      };
    }
    tradeStrategy(
      state,
      targetAt(state, state.now, options.targetPath),
      cfg.tickSeconds
    );
    if (step >= 0) {
      const debt = usd(state.debt),
        target = targetAt(state, state.now, options.targetPath);
      peakDebt = Math.max(peakDebt, debt);
      maxUnwindShortfall = Math.max(maxUnwindShortfall, debt - target);
      underTargetHollarHours += Math.max(0, target - debt) * tickHours;
      overTargetHollarHours += Math.max(0, debt - target) * tickHours;
    }
    const sample = () => {
      const marks = quoteMarks(state),
        stable = marks.filter((m) => m.id !== PRIME);
      const low = Math.min(...stable.map((m) => m.bid)),
        prime = marks.find((m) => m.id === PRIME).bid;
      if (step >= 0) {
        minStable = Math.min(minStable, low);
        minPrime = Math.min(minPrime, prime);
        maxStable = Math.max(maxStable, ...stable.map((m) => m.ask));
        maxSpread = Math.max(
          maxSpread,
          Math.max(...marks.map((m) => m.bid)) -
            Math.min(...marks.map((m) => m.ask))
        );
      }
      return low;
    };
    sample();
    externalBuy(state, cfg.tickSeconds);
    if (state.now + 1e-9 >= nextArb) {
      arbitrage(state);
      nextArb = state.now + cfg.arbEverySeconds / 3600;
    }
    rebalanceInventory(state);
    const beforeHsm = sample();
    advanceHsm(state, cfg.tickSeconds);
    const afterHsm = sample();
    if (step >= 0 && Math.min(beforeHsm, afterHsm) < 0.99)
      hoursBelow99 += tickHours;
    if (
      step >= 0 &&
      !options.targetPath &&
      completeHour === null &&
      usd(state.debt) >= state.gross - 1
    )
      completeHour = state.now + tickHours;
    if ((step + 1) % Math.round(24 / tickHours) === 0 && step >= 0) {
      assertConservation(state);
      daily.push({
        day: ((step + 1) * tickHours) / 24,
        target: targetAt(state, state.now, options.targetPath),
        debt: usd(state.debt),
        prices: quoteMarks(state),
        hsmHolding: state.hsm.rows.reduce((s, r) => s + usd(r.holding, 6), 0),
        hsmBurnCapacity: usd(state.hsm.burn),
        agentCash: usd(get(state.agent, USD), 6),
        mmCash: Object.fromEntries(
          Object.entries(state.mmCash).map(([k, v]) => [k, usd(v, 6)])
        ),
        buyerSpent: usd(state.initialBuyerCash - state.buyerCash, 6),
        unsettledValue: state.pending.reduce(
          (s, p) =>
            s +
            (p.id === USD ? usd(p.amount, 6) : value(state, p.id, p.amount)),
          0
        ),
      });
    }
  }
  assertConservation(state);
  const agentMarkedValue =
    Object.entries(state.agent).reduce(
      (sum, [id, q]) =>
        sum + (id === USD ? usd(q, 6) : value(state, Number(id), q)),
      0
    ) +
    state.pending.reduce(
      (sum, p) =>
        sum + (p.id === USD ? usd(p.amount, 6) : value(state, p.id, p.amount)),
      0
    );
  return {
    tvl: options.tvl || 1000000,
    grossRequested: state.gross,
    config: cfg,
    fulfilledFraction: usd(state.debt) / state.gross,
    finalDebt: usd(state.debt),
    completeHour,
    minStablePrice: minStable,
    minPrimePrice: minPrime,
    maxStableAsk: maxStable,
    maxCrossPoolSpread: maxSpread,
    hoursBelow99,
    finalPrices: quoteMarks(state),
    queuedHollar: Math.max(
      0,
      targetAt(state, cfg.days * 24 - tickHours, options.targetPath) -
        usd(state.debt)
    ),
    maxQueuedHollar: state.maxPending,
    guardCount: state.guardCount,
    entryHollar: usd(state.entryH),
    exitHollar: usd(state.exitH),
    strategyPrimeValue: oraclePrimeValue(state, state.strategyPrime),
    strategyPrimeFairValue: value(state, PRIME, state.strategyPrime),
    strategyHollar: usd(state.strategyH),
    hsmBurned: usd(state.hsmBurned),
    hsmMinted: usd(state.hsmMinted),
    hsmBurnRemaining: usd(state.hsm.burn),
    hsmHolding: state.hsm.rows.reduce((s, r) => s + usd(r.holding, 6), 0),
    arbCount: state.arbCount,
    arbHollarTurnover: state.arbH,
    arbMarkProfit: state.arbMarkProfit,
    gasUsd: usd(state.gas, 6),
    primeSubscribed: state.primeSubscribed,
    primeRedeemed: state.primeRedeemed,
    stableWithdrawn: state.stableWithdrawn,
    stableSupplied: state.stableSupplied,
    buyerSpent: usd(state.initialBuyerCash - state.buyerCash, 6),
    buyerHollarHeld: usd(state.buyerH),
    externalDebtRepaid: usd(state.externalDebtRepaid),
    settlementBlockedCash: state.settlementBlockedCash,
    mmCash: Object.fromEntries(
      Object.entries(state.mmCash).map(([k, v]) => [k, usd(v, 6)])
    ),
    agentMarkedPnl: agentMarkedValue - cfg.agentCapital,
    agentCash: usd(get(state.agent, USD), 6),
    agentInventory: Object.fromEntries(
      Object.entries(state.agent)
        .filter(([id]) => id !== USD)
        .map(([id, q]) => [id, value(state, Number(id), q)])
    ),
    unsettledValue: state.pending.reduce(
      (sum, p) =>
        sum + (p.id === USD ? usd(p.amount, 6) : value(state, p.id, p.amount)),
      0
    ),
    peakDebt,
    maxUnwindShortfall,
    underTargetHollarHours,
    overTargetHollarHours,
    finalTarget: targetAt(state, cfg.days * 24 - tickHours, options.targetPath),
    unpaidUnwindHollar: Math.max(
      0,
      usd(state.debt) -
        targetAt(state, cfg.days * 24 - tickHours, options.targetPath)
    ),
    stressLog: state.stressLog,
    baseline: state.baseline,
    daily,
    conservation: true,
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const snapshot = JSON.parse(readFileSync(process.argv[2]));
  const math = loadMath(process.env.HYDRATION_MATH_ROOT);
  const result = simulate(
    snapshot,
    math,
    JSON.parse(process.env.COUPLED_OPTIONS || "{}")
  );
  const output = process.argv[3] || "/tmp/propeller-coupled-case.json";
  result.snapshotSha256 = createHash("sha256")
    .update(readFileSync(process.argv[2]))
    .digest("hex");
  result.dependencies = math.dependencies;
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
  const { daily, config, finalPrices, baseline, ...summary } = result;
  console.log(output, summary);
}
