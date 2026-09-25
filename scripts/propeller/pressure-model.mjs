// Exposure/flow envelope plus official stable-swap/HSM math. Not a price forecast.
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
const require = createRequire(import.meta.url);
export const TVLS = [
  100_000, 500_000, 1_000_000, 10_000_000, 50_000_000, 100_000_000,
];
export const usd = (amount, decimals = 18) =>
  Number(BigInt(amount)) / 10 ** decimals;
export function prices(day, path) {
  if (path === "bull") return [1 + day / 90, 1 + (0.6 * day) / 90];
  if (path === "bear") return [1 - (0.7 * day) / 90, 1 - (0.6 * day) / 90];
  const phase = day % 20;
  const f = phase <= 10 ? 1 + phase * 0.04 : 1.4 - (phase - 10) * 0.08;
  return [f, f];
}
export function capacity(snapshot) {
  const m = snapshot.markets,
    market = snapshot.facilitators.find((f) => f.label === "Hydration Market");
  const hsm = snapshot.facilitators.find(
    (f) => f.label === "HOLLAR Stability Module"
  );
  const price = (symbol) => Number(m[symbol].price) / 1e8;
  const supplyRoom = (symbol) =>
    (Number(m[symbol].supplyCap) - usd(m[symbol].supply, m[symbol].decimals)) *
    price(symbol);
  const leverage = 1 / (1 - m.PRIME.ltBps / 10000 / 1.05);
  return {
    leverage,
    ltv: [m.ETH.ltvBps / 10000, m.tBTC.ltvBps / 10000],
    price: [price("ETH"), price("tBTC")],
    primePrice: price("PRIME"),
    marketMintRoom: usd(
      BigInt(market.bucketCapacity) - BigInt(market.bucketLevel)
    ),
    hsmMintRoom: usd(BigInt(hsm.bucketCapacity) - BigInt(hsm.bucketLevel)),
    hsmBurnCapacity: usd(hsm.bucketLevel),
    primeSupplyRoom: supplyRoom("PRIME"),
    ethSupplyRoom: supplyRoom("ETH"),
    btcSupplyRoom: supplyRoom("tBTC"),
    primeIsolationRoom:
      Number(m.PRIME.debtCeiling) / 100 -
      Number(m.PRIME.reserve.isolationModeTotalDebt) / 100,
    primeAvailable: usd(m.PRIME.availableLiquidity, 6) * price("PRIME"),
    ethAvailable: usd(m.ETH.availableLiquidity, 18) * price("ETH"),
    btcAvailable: usd(m.tBTC.availableLiquidity, 18) * price("tBTC"),
    borrowApr: Number(m.HOLLAR.reserve.currentVariableBorrowRate) / 1e27,
    hsmCollateral: snapshot.hsm.collaterals.reduce(
      (n, c) => n + usd(c.balance, c.info.decimals),
      0
    ),
  };
}

// Counterfactual requested exposure: full target leverage, external funding of
// Main interest/negative carry, no price impact. Capacity failures are reported,
// never silently interpreted as achievable TVL or an executable strategy.
export function envelope(
  tvl,
  path,
  c,
  { outage = false, discount = 0, exitFraction = 0 } = {}
) {
  const units = [tvl / 2 / c.price[0], tvl / 2 / c.price[1]];
  const initialEquity = (tvl * (c.ltv[0] + c.ltv[1])) / 2;
  let equity = initialEquity,
    gross = equity * c.leverage;
  let sellHollar = gross,
    buyHollar = 0,
    harvest = 0,
    fees = 0,
    mainInterest = 0,
    negativeCarry = 0;
  let peakDebt = gross,
    peakGross = gross,
    operatingPeakSell = 0,
    operatingPeakBuy = 0;
  let compounded = 0,
    exited = false,
    missedMainInterest = 0,
    pendingHarvest = 0;
  const daily = [];
  for (let day = 1; day <= 90; day++) {
    const factors = prices(day, path);
    const rate =
      path === "bear"
        ? 0.12
        : path === "seesaw"
        ? day % 20 < 10
          ? 0.025
          : 0.12
        : c.borrowApr;
    const primeYield =
      path === "bear" ? 0.04 : path === "seesaw" ? 0.055 : 0.065;
    const interest = (equity * rate * (1 - discount)) / 365;
    mainInterest += interest;
    const net = (gross * primeYield) / 365 - ((gross - equity) * rate) / 365;
    const gain = Math.max(0, net),
      loss = Math.max(0, -net);
    negativeCarry += loss;
    pendingHarvest += gain;
    const offline = outage && day >= 21 && day <= 50;
    let sale = 0,
      purchase = 0,
      realized = 0;
    missedMainInterest += interest;
    if (!offline) {
      // Funding is explicit in this envelope; the Solidity campaign separately
      // tests the actual blocked-rebalance behavior without these subsidies.
      missedMainInterest = 0;
      realized = pendingHarvest;
      pendingHarvest = 0;
      harvest += realized;
      fees += realized * 0.05;
      for (let i = 0; i < 2; i++)
        units[i] += (realized * 0.95) / 2 / (c.price[i] * factors[i]);
      compounded += realized * 0.95;
      if (day >= 60 && !exited && exitFraction > 0) {
        for (let i = 0; i < 2; i++) units[i] *= 1 - exitFraction;
        exited = true;
      }
      const desired = units.reduce(
        (n, u, i) => n + u * c.price[i] * factors[i] * c.ltv[i],
        0
      );
      const change = desired - equity;
      // Keep existing hysteresis approximately: lower gap 5%, upper gap 3%
      // of collateral, not 5/3% of debt. This model aggregates the two vaults.
      const collateral = units.reduce(
        (n, u, i) => n + u * c.price[i] * factors[i],
        0
      );
      if (
        change > collateral * 0.05 ||
        change < -collateral * 0.03 ||
        (day === 60 && exited)
      ) {
        const flow = change * c.leverage;
        sale = Math.max(0, flow);
        purchase = Math.max(0, -flow);
        equity = desired;
        gross = equity * c.leverage;
      }
      // PRIME-to-collateral harvesting buys HOLLAR on the PRIME first hop and
      // then sells it on the collateral leg; don't call this net HOLLAR burn.
      buyHollar += realized;
    }
    sellHollar += sale;
    buyHollar += purchase;
    peakDebt = Math.max(peakDebt, gross);
    peakGross = Math.max(peakGross, gross);
    operatingPeakSell = Math.max(operatingPeakSell, sale);
    operatingPeakBuy = Math.max(operatingPeakBuy, purchase);
    daily.push({
      day,
      ethFactor: factors[0],
      btcFactor: factors[1],
      equity,
      gross,
      loopDebt: gross - equity,
      mainInterest: interest,
      negativeCarry: loss,
      harvest: realized,
      borrowApr: rate,
      primeYieldApr: primeYield,
      sellHollar: sale,
      buyHollar: purchase,
      keeperOffline: offline,
      unservicedMainInterest: missedMainInterest,
    });
  }
  return {
    tvl,
    path,
    outage,
    discount,
    exitFraction,
    initialEquity,
    initialGross: initialEquity * c.leverage,
    peakDebt,
    peakGross,
    sellHollar,
    buyHollar,
    operatingPeakSell,
    operatingPeakBuy,
    finalGross: gross,
    finalMainDebt: equity,
    fullExitHollarDemand: gross,
    primeExitLiquidityRatio: gross / (c.primeAvailable + gross),
    mainInterest,
    negativeCarry,
    externalFunding: mainInterest + negativeCarry,
    harvest,
    fees,
    compounded,
    breaches: {
      marketMint: peakDebt > c.marketMintRoom,
      primeSupply: peakGross > c.primeSupplyRoom,
      primeIsolation: peakGross * (1 - 1 / c.leverage) > c.primeIsolationRoom,
      ethSupply: tvl / 2 > c.ethSupplyRoom,
      btcSupply: tvl / 2 > c.btcSupplyRoom,
    },
    daily,
  };
}

export function loadMath(root) {
  const stable = require(root
    ? `${root}/math-stableswap/build/index.cjs`
    : "@galacticcouncil/math-stableswap");
  const hsm = require(root
    ? `${root}/math-hsm/build/index.cjs`
    : "@galacticcouncil/math-hsm");
  const dependencies = {};
  for (const name of ["stableswap", "hsm"]) {
    const entry = root
      ? `${root}/math-${name}`
      : require
          .resolve(`@galacticcouncil/math-${name}/package.json`)
          .replace(/\/package.json$/, "");
    dependencies[name] = {
      version: JSON.parse(readFileSync(`${entry}/package.json`)).version,
      wasmSha256: createHash("sha256")
        .update(readFileSync(`${entry}/build/hydra_dx_wasm_bg_nodejs.wasm`))
        .digest("hex"),
    };
  }
  return { stable, hsm, dependencies };
}
export class QuoteRejected extends Error {
  constructor() {
    super("stable-swap math rejected quote");
  }
}

// Monotone oracle-floor capacity above a one-HOLLAR probe. A failed marginal
// trade means zero usable entry, not a search through sub-token rounding dust.
export function maximumInput(quote, acceptable, limit) {
  if (limit <= 0n) return 0n;
  const probe = limit < 10n ** 18n ? limit : 10n ** 18n;
  const succeeds = (input) => {
    let output;
    try {
      output = quote(input);
    } catch (error) {
      if (error instanceof QuoteRejected) return false;
      throw error;
    }
    return output > 0n && acceptable(output, input);
  };
  if (!succeeds(probe)) return 0n;
  let low = probe,
    high = limit;
  while (low < high) {
    const mid = (low + high + 1n) / 2n;
    if (succeeds(mid)) low = mid;
    else high = mid - 1n;
  }
  return low;
}

export function poolQuote(
  stable,
  pool,
  assetIn,
  assetOut,
  amount,
  exactOut = false
) {
  if (amount === 0n) return 0n;
  const reserves = JSON.stringify(
    pool.reserves.map((r) => ({
      asset_id: r.id,
      amount: r.balance,
      decimals: r.info.decimals,
    }))
  );
  const pegs = JSON.stringify(
    (pool.pegs?.current || pool.reserves.map(() => [1, 1])).map((a) =>
      a.map((n) => BigInt(n).toString())
    )
  );
  const output = (
    exactOut ? stable.calculate_in_given_out : stable.calculate_out_given_in
  )(
    reserves,
    assetIn,
    assetOut,
    amount.toString(),
    String(pool.info.finalAmplification),
    String(pool.info.fee / 1e6),
    pegs
  );
  if (BigInt(output) < 0n) throw new QuoteRejected();
  return BigInt(output);
}
export function hsmCapacity(snapshot, math) {
  const burnCapacity = usd(
    snapshot.facilitators.find((f) => f.label === "HOLLAR Stability Module")
      .bucketLevel
  );
  return snapshot.hsm.collaterals.map((c) => {
    const p = snapshot.pools[c.config.poolId],
      h = p.reserves.find((r) => r.id === 222),
      a = p.reserves.find((r) => r.id === c.id);
    const peg = JSON.stringify([
      (10n ** 18n).toString(),
      (10n ** BigInt(c.info.decimals)).toString(),
    ]);
    const imbalance = math.hsm.calculate_imbalance(h.balance, peg, a.balance);
    const limit = math.hsm.calculate_buyback_limit(
      imbalance,
      String(c.config.buybackRate / 1e9)
    );
    // The runtime also gates on the executable pool price and available holdings.
    const bought = poolQuote(math.stable, p, c.id, 222, BigInt(limit), true);
    const adjusted = math.hsm.calculate_buyback_price_with_fee(
      bought.toString(),
      limit,
      String(c.config.buyBackFee / 1e6)
    );
    const max = math.hsm.calculate_max_price(
      peg,
      String(Number(BigInt(c.config.maxBuyPriceCoefficient)) / 1e18)
    );
    const [an, ad] = JSON.parse(adjusted).map(BigInt),
      [mn, md] = JSON.parse(max).map(BigInt);
    return {
      assetId: c.id,
      holding: usd(c.balance, c.info.decimals),
      maxHolding: usd(c.config.maxInHolding, c.info.decimals),
      imbalance: usd(imbalance),
      buybackRate: c.config.buybackRate / 1e9,
      limitPerBlock: usd(limit),
      priceEligible: an * md <= mn * ad,
      availableBuybackPerBlock:
        an * md <= mn * ad
          ? Math.min(usd(limit), usd(c.balance, c.info.decimals), burnCapacity)
          : 0,
      blocksToReduceImbalance95pct: Math.ceil(
        Math.log(0.05) / Math.log(1 - c.config.buybackRate / 1e9)
      ),
    };
  });
}

export function hsmSpillover(snapshot, math, hollarIn) {
  const after = structuredClone(snapshot),
    slices = after.hsm.collaterals.length;
  let collateralTaken = 0;
  // Sensitivity, not a forecast of arbitrage routing: spread the selected
  // HOLLAR sell flow equally across the two HSM-supported stable pools.
  for (const c of after.hsm.collaterals) {
    const p = after.pools[c.config.poolId];
    const amount = BigInt(Math.round((hollarIn / slices) * 1e6)) * 10n ** 12n;
    const output = poolQuote(math.stable, p, 222, c.id, amount);
    const h = p.reserves.find((r) => r.id === 222),
      a = p.reserves.find((r) => r.id === c.id);
    h.balance = (BigInt(h.balance) + amount).toString();
    a.balance = (BigInt(a.balance) - output).toString();
    collateralTaken += usd(output, c.info.decimals);
  }
  const rows = hsmCapacity(after, math),
    holding = rows.reduce((n, r) => n + r.holding, 0),
    burnCapacity = usd(
      after.facilitators.find((f) => f.label === "HOLLAR Stability Module")
        .bucketLevel
    );
  return {
    assumedHollarSpillover: hollarIn,
    stableCollateralSold: collateralTaken,
    rateCeilingPerBlock: rows.reduce((n, r) => n + r.limitPerBlock, 0),
    priceEligibleBuybackPerBlock: Math.min(
      burnCapacity,
      rows.reduce((n, r) => n + r.availableBuybackPerBlock, 0)
    ),
    sharedBurnCapacity: burnCapacity,
    reserveCoverage:
      hollarIn === 0
        ? 1
        : Math.min(1, Math.min(holding, burnCapacity) / hollarIn),
    rows,
  };
}

export function primeGapStress(tvl, c, lossFraction) {
  const mainDebt = (tvl * (c.ltv[0] + c.ltv[1])) / 2;
  const gross = mainDebt * c.leverage,
    loopDebt = gross - mainDebt;
  const remainingPrime = gross * (1 - lossFraction);
  const loopBadDebt = Math.max(0, loopDebt - remainingPrime);
  const sourceEquity = Math.max(0, remainingPrime - loopDebt);
  const mainBackingDeficit = Math.max(0, mainDebt - sourceEquity);
  return {
    tvl,
    lossFraction,
    healthFactor: 1.05 * (1 - lossFraction),
    loopBadDebt,
    mainBackingDeficit,
    protocolFundingBeforeFees: loopBadDebt + mainBackingDeficit,
  };
}

export function run(snapshot, math) {
  const c = capacity(snapshot),
    pool = snapshot.pools[143];
  const entries = TVLS.map((tvl) => {
    const main = (tvl * (c.ltv[0] + c.ltv[1])) / 2,
      gross = main * c.leverage;
    const quote = (dollars) => {
      const out = poolQuote(
        math.stable,
        pool,
        222,
        43,
        BigInt(Math.round(dollars * 1e6)) * 10n ** 12n
      );
      return {
        hollarIn: dollars,
        primeOut: usd(out, 6),
        oracleLossBps: (1 - (usd(out, 6) * c.primePrice) / dollars) * 10000,
      };
    };
    return {
      tvl,
      mainDebt: main,
      loopDebt: gross - main,
      grossPrimeDemand: gross,
      mainEntry: quote(main),
      fullRamp: quote(gross),
      exceedsMarketMint: gross > c.marketMintRoom,
      primePoolInventoryRatio:
        gross /
        (usd(pool.reserves.find((r) => r.id === 43).balance, 6) * c.primePrice),
    };
  });
  // No replenishment/arb: find the largest aggregate entry within a 1% oracle
  // floor. This is a sensitivity assumption, NOT an approved production limit.
  // Compare in USD8*1e12 units directly; avoid a hidden decimal mismatch.
  const entryCapacity = maximumInput(
    (input) => poolQuote(math.stable, pool, 222, 43, input),
    (out, input) =>
      out * BigInt(snapshot.markets.PRIME.price) * 10n ** 12n * 100n >=
      input * 10n ** 8n * 99n,
    100_000_000n * 10n ** 18n
  );
  const scenarios = [];
  for (const tvl of TVLS)
    for (const path of ["bull", "bear", "seesaw"])
      for (const outage of [false, true])
        for (const discount of [0, 0.5, 1]) {
          const s = envelope(tvl, path, c, {
            outage,
            discount,
            exitFraction: 0.5,
          });
          const quoteExit = (dollars) => {
            const input = BigInt(Math.floor((dollars / c.primePrice) * 1e6));
            const out = poolQuote(math.stable, pool, 43, 222, input);
            return {
              primeValueSold: dollars,
              hollarReceived: usd(out),
              oracleLossBps: (1 - usd(out) / dollars) * 10000,
            };
          };
          s.exitQuoteAtSnapshot = quoteExit(s.fullExitHollarDemand);
          s.peakUnwindQuoteAtSnapshot =
            s.operatingPeakBuy > 0 ? quoteExit(s.operatingPeakBuy) : null;
          s.peakSellHsmQuarterSpillover = hsmSpillover(
            snapshot,
            math,
            s.operatingPeakSell * 0.25
          );
          // Independent counterfactual cash-availability shocks. These are not
          // utilization forecasts and may require reserve-cap changes at large TVL.
          s.exitLiquidityShocks = [1, 0.5, 0.1].map((fraction) => ({
            availableFraction: fraction,
            primeShortfall: Math.max(
              0,
              s.finalGross - (c.primeAvailable + s.finalGross) * fraction
            ),
            ethPrincipalShortfall: Math.max(
              0,
              tvl / 4 - (c.ethAvailable + tvl / 2) * fraction
            ),
            btcPrincipalShortfall: Math.max(
              0,
              tvl / 4 - (c.btcAvailable + tvl / 2) * fraction
            ),
          }));
          scenarios.push(s);
        }
  const spillovers = entries.flatMap((e) =>
    [0.1, 0.25, 1].map((fraction) => ({
      tvl: e.tvl,
      fraction,
      ...hsmSpillover(snapshot, math, e.grossPrimeDemand * fraction),
    }))
  );
  return {
    snapshotBlock: snapshot.block,
    snapshotHash: snapshot.hash,
    mathDependencies: math.dependencies,
    capacity: c,
    hsm: hsmCapacity(snapshot, math),
    entries,
    spillovers,
    primeGapStress: TVLS.flatMap((tvl) =>
      [0.05, 0.1, 0.25, 1].map((loss) => primeGapStress(tvl, c, loss))
    ),
    noRefillEntryAtOnePercent: usd(entryCapacity),
    scenarios,
    assumptions: [
      "50/50 initial deposited collateral value, six TVL levels, 90 daily steps",
      "Bull ETH +100% / tBTC +60%; bear -70% / -60%; seesaw 0.68x to 1.4x with a 20-day reset",
      "PRIME yield APR scenarios 6.5% / 4% / 5.5%, not observed forward yields",
      "Borrow APR bull from pinned market, bear 12%, seesaw 2.5%/12%; 5% harvested-yield fee",
      "Main discount 0/50/100%; loop always undiscounted; 50% withdrawal on day 60, remaining full exit day 90",
      "Outage days 21-50 delays resizing; independent Solidity tests validate unfunded behavior",
      "Exposure envelope assumes external Main-interest/negative-carry funding; not an executable fill simulation",
      "Static quotes use official WASM stable-swap math, snapshot pegs/fees; no arb, refill, future oracle drift or circuit-breaker bypass",
      "HSM capacities are conditional ceilings, not promised buybacks; holdings at nominal parity, shared facilitator burn level and per-block price/rate limits apply",
      "No prior same-block HSM flow, underlying aToken illiquidity, flash-loan limits or additional circuit-breaker consumption modeled; these can further restrict execution",
      "Aggregate resizing and 50/50 USD harvest allocation approximate the two vaults; not a per-vault source-share simulation",
      "Daily-peak and exit quotes reset to the snapshot, not an endogenous 90-day pool trajectory",
      "Cash-availability sensitivities 100/50/10% are counterfactuals, not predicted utilization",
      "PRIME gap-loss bounds assume instant 5/10/25/100% asset-value shocks before liquidation; exclude liquidation penalties and execution costs",
      "HSM does not hold/accept PRIME here; stablecoin arbitrage cannot be assumed to refill PRIME inventory",
    ],
  };
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const snapshot = JSON.parse(readFileSync(process.argv[2]));
  const result = run(snapshot, loadMath(process.env.HYDRATION_MATH_ROOT));
  const output = process.argv[3] || "/tmp/propeller-pressure-results.json";
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
  const fields = [
    "tvl",
    "path",
    "outage",
    "discount",
    "exitFraction",
    "initialEquity",
    "initialGross",
    "peakDebt",
    "sellHollar",
    "buyHollar",
    "operatingPeakSell",
    "operatingPeakBuy",
    "fullExitHollarDemand",
    "mainInterest",
    "negativeCarry",
    "externalFunding",
    "harvest",
    "fees",
  ];
  writeFileSync(
    output.replace(/\.json$/, ".csv"),
    [
      fields.join(","),
      ...result.scenarios.map((s) => fields.map((f) => s[f]).join(",")),
    ].join("\n") + "\n"
  );
  console.log(
    JSON.stringify(
      {
        output,
        capacity: result.capacity,
        hsm: result.hsm,
        entries: result.entries,
        noRefillEntryAtOnePercent: result.noRefillEntryAtOnePercent,
        scenarios: result.scenarios.length,
      },
      null,
      2
    )
  );
}
