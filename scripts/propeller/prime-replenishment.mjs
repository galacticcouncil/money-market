// Snapshot economics: trades, reserves and bridge capacity are not commitments.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { loadMath, poolQuote, capacity, TVLS } from "./pressure-model.mjs";
import { classifyActions, quantile } from "./neckwork-calibration.mjs";
import { sellPrime, lossBps } from "./route-calibration.mjs";
const WAD = 10n ** 18n;
export function refillCapacity(limit, remaining, last, now, duration = 86400n) {
  assert.ok(
    limit >= 0n &&
      remaining >= 0n &&
      remaining <= limit &&
      now >= last &&
      duration > 0n
  );
  const value = remaining + ((now - last) * limit) / duration;
  return value < limit ? value : limit;
}
export function minimumRefill(accepts, upper) {
  assert.ok(upper >= 0n);
  if (accepts(0n)) return 0n;
  if (!accepts(upper)) return null;
  let lo = 0n,
    hi = upper;
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n;
    if (accepts(mid)) hi = mid;
    else lo = mid;
  }
  return hi;
}
export function validation(market, solana, history, math) {
  const end = Date.parse(history.window.toExclusive) / 1000,
    from = end - 30 * 86400;
  assert.ok(
    history.activityCoverage.exhausted,
    "incomplete activity pagination"
  );
  const rows = Object.entries(history.sources)
    .filter(([k]) => k.startsWith("prime-trades-"))
    .flatMap(([, v]) => v.data);
  const actions = classifyActions(rows, from, end),
    daily = Object.values(actions.days);
  const sold = actions.accepted.filter((x) => x.direction === "sell"),
    sum = sold.reduce((n, x) => n + x.usd, 0);
  const actors = {};
  for (const x of sold) actors[x.account] = (actors[x.account] || 0) + x.usd;
  const times = [
    from,
    ...sold.filter((x) => x.usd >= 1000).map((x) => x.time),
    end,
  ];
  const gaps = times.slice(1).map((x, i) => (x - times[i]) / 3600);
  const price = BigInt(solana.configuration.price.price),
    scale = BigInt(solana.configuration.price.priceScale);
  const reference8 = (price * 100000000n) / scale;
  const cost = (q) => (q * price) / scale;
  const original = market.pools[143],
    usdcPool = market.pools[110];
  const cases = [];
  for (const updated of [false, true]) {
    const pool = structuredClone(original),
      guard = updated ? reference8 : BigInt(market.markets.PRIME.price);
    if (updated)
      pool.pegs.current[pool.reserves.findIndex((x) => x.id === 43)] = [
        reference8.toString(),
        "100000000",
      ];
    const after = (q) => sellPrime(math.stable, pool, q);
    const entryPass = (q, bps) => {
      const out = poolQuote(math.stable, after(q).pool, 222, 43, 1000n * WAD);
      return (
        out * guard * 10n ** 12n * 10000n >=
        1000n * WAD * 100000000n * BigInt(10000 - bps)
      );
    };
    const required = Object.fromEntries(
      [25, 50, 100].map((bps) => {
        const q = minimumRefill((x) => entryPass(x, bps), 300000n * 1000000n);
        return [bps, q === null ? null : Number(q) / 1e6];
      })
    );
    const quotes = [1000, 10000, 50000, 100000, 150000].map((amount) => {
      const input = BigInt(amount) * 1000000n,
        r = after(input),
        out = poolQuote(math.stable, usdcPool, 222, 1003, r.output),
        expense = cost(input);
      return {
        prime: amount,
        hollar: Number(r.output) / 1e18,
        usdcAfterPool110: Number(out) / 1e6,
        costUsdcAtReference: Number(expense) / 1e6,
        edgeBps: Number(((out - expense) * 1000000n) / expense) / 100,
        next1000HollarEntryLossBps: lossBps(
          1000n * WAD,
          poolQuote(math.stable, r.pool, 222, 43, 1000n * WAD),
          guard
        ),
      };
    });
    cases.push({
      name: updated
        ? "conditional-oracle-and-pool-peg-updated"
        : "current-oracle-and-peg",
      minimumPrimeRefillFor1000HollarEntry: required,
      quotes,
    });
  }
  const c = capacity(market),
    grossPerTvl = ((c.ltv[0] + c.ltv[1]) / 2) * c.leverage;
  return {
    snapshot: {
      block: market.block,
      hash: market.hash,
      solanaSlot: solana.slot,
    },
    reference: {
      ...solana.reference,
      hydrationActive: Number(market.markets.PRIME.price) / 1e8,
      activeDiscountBps:
        (Number(price) /
          Number(scale) /
          (Number(market.markets.PRIME.price) / 1e8) -
          1) *
        10000,
    },
    liquidity: solana.liquidity,
    redemption: {
      ...solana.redemptionRequests,
      nominalCashGap: Math.max(
        0,
        solana.redemptionRequests.requestedWylds -
          solana.liquidity.usdcRedemptionVault
      ),
      caveat:
        "Requests and cash are near-contemporaneous, not atomically pinned. Not proof of insolvency, executable requests or settlement time.",
    },
    bridge: solana.bridge,
    history: {
      from: new Date(from * 1000).toISOString(),
      toExclusive: new Date(end * 1000).toISOString(),
      classifiedActions: actions.accepted.length,
      excludedWrappers: actions.excludedWrappers,
      excludedUnresolved: actions.excludedUnresolved,
      primeSold: Number(actions.totalPrimeSoldRaw) / 1e6,
      primeBought: Number(actions.totalPrimeBoughtRaw) / 1e6,
      netPrimeSold:
        Number(
          BigInt(actions.totalPrimeSoldRaw) -
            BigInt(actions.totalPrimeBoughtRaw)
        ) / 1e6,
      meanSellUsdPerDay: sum / 30,
      medianSellUsdPerDay: quantile(
        daily.map((d) => d.sellUsd),
        0.5
      ),
      p90SellUsdPerDay: quantile(
        daily.map((d) => d.sellUsd),
        0.9
      ),
      maxSellUsdPerDay: Math.max(...daily.map((d) => d.sellUsd)),
      daysUnder1000UsdSales: daily.filter((d) => d.sellUsd < 1000).length,
      longestGapBetween1000UsdSalesHours: Math.max(...gaps),
      largestSellerShare: Math.max(...Object.values(actors)) / sum,
      observedDaily: actions.days,
      limitation:
        "Endpoint actions, not all pool legs or proven cross-chain arbitrage. Gaps include censored window boundaries; historical activity is not an SLA.",
    },
    scenarios: cases,
    ramp: TVLS.map((tvl) => ({
      tvl,
      grossHollar: tvl * grossPerTvl,
      hollarPerDayFor30DayRamp: (tvl * grossPerTvl) / 30,
      primePerDayAtReference:
        (tvl * grossPerTvl) / 30 / (Number(price) / Number(scale)),
      multipleOfObservedGrossDailySells: (tvl * grossPerTvl) / sum,
    })),
    limitations: [
      "wYLDS acquisition modeled at 1 USDC as per mint source; not independent off-chain backing verification.",
      "SDK pool143 -> pool110 quotes include pool fees but omit bridging, gas, settlement/funding costs, concurrent flow, HSM reactions and future price moves. No transaction submitted.",
      "Pool110 output is aUSDC; converting it to USDC depends on Aave cash. No other venues or external trader inventories are assumed.",
      "An oracle/peg update is hypothetical and not approved; replenishment is not guaranteed even when an arbitrage quote has positive gross edge.",
    ],
    providerCommitmentVerified: false,
  };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const [marketFile, solanaFile, historyFile, output] = process.argv.slice(2);
  assert.ok(output);
  const j = (f) => JSON.parse(readFileSync(f));
  const r = validation(
    j(marketFile),
    j(solanaFile),
    j(historyFile),
    loadMath(process.env.HYDRATION_MATH_ROOT)
  );
  writeFileSync(output, JSON.stringify(r, null, 2) + "\n");
  console.log(
    JSON.stringify(
      {
        history: { ...r.history, observedDaily: undefined },
        scenarios: r.scenarios,
        ramp: r.ramp,
      },
      null,
      2
    )
  );
}
