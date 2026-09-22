// Comparative economic model, not EVM execution or a liquidity forecast.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { capacity, prices, TVLS } from "./pressure-model.mjs";

export const POLICIES = ["current", "harvest", "withdrawal", "buffer"];
export const PATHS = ["flat", "bull", "bear", "seesaw", "rallyCrash"];
const positive = (n) => Math.max(0, n);

export function market(day, path, borrowApr) {
  if (!PATHS.includes(path)) throw new Error("unknown market path");
  if (path === "rallyCrash") {
    const afterPeak = Math.max(0, day - 45) / 45;
    return {
      factors:
        day <= 45
          ? [1 + day / 90, 1 + day / 150]
          : [1.5 - 1.2 * afterPeak, 1.3 - 0.9 * afterPeak],
      rate: day <= 45 ? borrowApr : 0.12,
      primeApr: day <= 45 ? 0.065 : 0.04,
    };
  }
  const rate =
    path === "bear"
      ? 0.12
      : path === "seesaw"
      ? day % 20 < 10
        ? 0.025
        : 0.12
      : borrowApr;
  return {
    factors: path === "flat" ? [1, 1] : prices(day, path),
    rate,
    primeApr: path === "bear" ? 0.04 : path === "seesaw" ? 0.055 : 0.065,
  };
}

export function headroom(collateralValue, ltv, debtIncludingInterest) {
  return positive(collateralValue * ltv - debtIncludingInterest);
}

// Same-token principal is an explicit model ledger, not a claim that the current
// transferable vault shares implement position-level principal attribution.
export function sellableYield(collateral, principal) {
  return positive(collateral - principal);
}

function wealth(v, price) {
  return v.collateral * price + v.equity + v.reserve - v.debt;
}

function recordCost(v, dollars, kind) {
  v.costs += dollars;
  v[kind] += dollars;
}

function buyHollar(v, units, price, cost) {
  if (units <= 0) return 0;
  const gross = units * price;
  recordCost(v, gross * cost, "reverseCosts");
  v.reverseVolume += gross;
  v.reverseSwaps++;
  return gross * (1 - cost);
}

// Source equity is withdrawn proportionally with its loop debt. A route-cost
// sensitivity applies to the GROSS PRIME sale, not just net equity recovered.
function withdrawSource(v, fraction, routeCost) {
  fraction = Math.min(1, Math.max(0, fraction));
  const gross = (v.equity + v.loopDebt) * fraction;
  const proceeds = v.equity * fraction - gross * routeCost;
  assert.ok(
    proceeds >= -1e-6,
    "source sale cannot repay loop debt at this route cost"
  );
  recordCost(v, gross * routeCost, "loopCosts");
  v.loopSellVolume += gross;
  v.equity *= 1 - fraction;
  v.loopDebt *= 1 - fraction;
  v.basis *= 1 - fraction;
  return Math.max(0, proceeds);
}

function maintainLoop(v, leverage, routeCost) {
  const k = leverage - 1;
  assert.ok(k * routeCost < 1);
  const gap = k * v.equity - v.loopDebt;
  if (gap >= 0) {
    const borrow = gap / (1 + k * routeCost);
    v.loopDebt += borrow;
    v.equity -= borrow * routeCost;
    v.loopBuyVolume += borrow;
    recordCost(v, borrow * routeCost, "loopCosts");
  } else {
    const repay = Math.min(v.loopDebt, -gap / (1 - k * routeCost));
    v.loopDebt -= repay;
    v.equity -= repay * routeCost;
    v.loopSellVolume += repay;
    recordCost(v, repay * routeCost, "loopCosts");
  }
}

function repayReserve(v) {
  // Unharvested source equity can back Main debt. Repayment addresses the
  // actual gap, which may include realized source losses as well as interest.
  const paid = Math.min(v.reserve, positive(v.debt - v.equity));
  v.debt -= paid;
  v.reserve -= paid;
  v.yieldDebtPayments += paid;
}

function harvest(v, price, rate, config) {
  const gross = positive(v.equity - v.basis);
  const threshold = v.basis * 0.001;
  if (gross <= threshold || gross <= 1e-9) return;
  v.equity -= gross;
  v.harvested += gross;
  v.forwardVolume += gross;
  v.forwardSwaps++;
  recordCost(v, gross * config.swapCost, "forwardCosts");
  const received = (gross * (1 - config.swapCost)) / price;
  const fee = received * config.fee;
  v.fees += fee * price;
  let fresh = received - fee;
  if (config.policy === "harvest" || config.policy === "buffer") {
    const gap = positive(v.debt - v.equity);
    const target =
      config.policy === "buffer"
        ? (v.debt * rate * (1 - config.discount) * config.bufferDays) / 365 +
          ((v.equity + v.loopDebt) * config.exitCostReserveBps) / 10000
        : 0;
    const desiredCash = positive(gap + target - v.reserve);
    const units = Math.min(
      fresh,
      desiredCash / (price * (1 - config.swapCost))
    );
    v.reserve += buyHollar(v, units, price, config.swapCost);
    fresh -= units;
    repayReserve(v);
  }
  v.collateral += fresh;
}

function eligibleBacking(v, price, config) {
  const extra =
    config.policy === "withdrawal"
      ? sellableYield(v.collateral, v.principal) * price * (1 - config.swapCost)
      : 0;
  return v.equity + v.reserve + extra;
}

function rebalance(v, price, config) {
  const value = v.collateral * price;
  const gap = headroom(value, v.ltv, v.debt);
  if (gap > value * 0.05) {
    // Withdrawal-time servicing needs a DIFFERENT, principal-aware backing
    // check. Existing code does not count compounded yield in this comparison.
    if (
      eligibleBacking(v, price, config) + 1e-6 < v.debt ||
      v.equity + 1e-6 < v.basis
    ) {
      v.blockedRebalances++;
      return;
    }
    v.debt += gap;
    v.equity += gap * (1 - config.loopRouteCost);
    v.basis += gap;
    v.loopBuyVolume += gap;
    recordCost(v, gap * config.loopRouteCost, "loopCosts");
    v.newBorrowing += gap;
  } else if (v.debt > value * (v.ltv + 0.03)) {
    const desired = v.debt - value * v.ltv;
    const available = v.equity - (v.equity + v.loopDebt) * config.loopRouteCost;
    const fraction = available > 0 ? Math.min(1, desired / available) : 0;
    const proceeds = withdrawSource(v, fraction, config.loopRouteCost);
    v.debt -= proceeds;
    v.sourceRepayments += proceeds;
  }
}

function closeSlice(v, fraction, day, price, rate, config) {
  const cut = {};
  for (const key of [
    "principal",
    "collateral",
    "debt",
    "equity",
    "loopDebt",
    "basis",
    "reserve",
  ]) {
    cut[key] = v[key] * fraction;
    v[key] -= cut[key];
  }
  const debtAtStart = cut.debt;
  // Isolated unwind-delay stress: lock the source quote and collateral price
  // at start, but let this exiting slice's OWN Main interest continue accruing.
  // No remaining-holder subsidy and no assertion of native unwind execution.
  const delayInterest =
    cut.debt *
    ((1 + (rate * (1 - config.discount)) / 365) ** config.exitLagDays - 1);
  cut.debt += delayInterest;
  v.mainInterest += delayInterest;
  v.exitDelayInterest += delayInterest;
  const sourceCost = (cut.equity + cut.loopDebt) * config.loopRouteCost;
  recordCost(v, sourceCost, "loopCosts");
  v.loopSellVolume += cut.equity + cut.loopDebt;
  let cash = Math.max(0, cut.equity - sourceCost) + cut.reserve;
  const beforeYield = positive(cut.debt - cash);
  let sold = 0;
  if (config.policy === "withdrawal" && beforeYield > 0) {
    sold = Math.min(
      sellableYield(cut.collateral, cut.principal),
      beforeYield / (price * (1 - config.swapCost))
    );
    cash += buyHollar(v, sold, price, config.swapCost);
    cut.collateral -= sold;
  }
  const funding = positive(cut.debt - cash);
  const economicYieldAvailable =
    sellableYield(cut.collateral, cut.principal) *
    price *
    (1 - config.swapCost);
  const minimumPrincipalSupport = positive(funding - economicYieldAvailable);
  if (funding > 1e-6) v.unfundedExits++;
  v.governanceFunding += funding;
  v.minimumPrincipalSupport += minimumPrincipalSupport;
  // Explicit hypothetical funding is booked ONLY to finish the comparison.
  // Without it, a short claim stays pending; this is not automatic treasury access.
  cash += funding;
  const surplus = positive(cash - cut.debt);
  if (surplus > 1e-8) {
    v.forwardVolume += surplus;
    v.forwardSwaps++;
    recordCost(v, surplus * config.swapCost, "forwardCosts");
    cut.collateral += (surplus * (1 - config.swapCost)) / price;
  }
  assert.ok(
    cut.collateral + 1e-12 >= cut.principal,
    "principal must not be sold"
  );
  const paidValue = cut.collateral * price;
  v.paidUnits += cut.collateral;
  v.paidValue += paidValue;
  v.supportInUnits += funding / price;
  v.minimumSupportInUnits += minimumPrincipalSupport / price;
  const userYield = (cut.collateral - cut.principal) * price;
  v.exits.push({
    day,
    fraction,
    price,
    principalUnits: cut.principal,
    paidUnits: cut.collateral,
    debtAtStart,
    debtAtSettlement: cut.debt,
    delayInterest,
    loopEquity: cut.equity,
    reserve: cut.reserve,
    soldYieldUnits: sold,
    funding,
    minimumPrincipalSupport,
    userYield,
    paidValue,
  });
}

function initialVault(c, tvl, i) {
  const price = c.price[i],
    initialValue = tvl / 2,
    debt = initialValue * c.ltv[i];
  const zeroes = [
    "reserve",
    "fees",
    "costs",
    "forwardCosts",
    "reverseCosts",
    "loopCosts",
    "forwardVolume",
    "reverseVolume",
    "forwardSwaps",
    "reverseSwaps",
    "loopBuyVolume",
    "loopSellVolume",
    "mainInterest",
    "loopInterest",
    "primeIncome",
    "harvested",
    "newBorrowing",
    "sourceRepayments",
    "yieldDebtPayments",
    "governanceFunding",
    "minimumPrincipalSupport",
    "supportInUnits",
    "minimumSupportInUnits",
    "paidUnits",
    "paidValue",
    "pricePnl",
    "blockedRebalances",
    "unfundedDays",
    "unfundedExits",
    "exitDelayInterest",
    "peakGap",
    "peakDebt",
    "peakGross",
    "reserveDays",
    "peakReserve",
    "conservationError",
  ];
  return {
    ...Object.fromEntries(zeroes.map((k) => [k, 0])),
    symbol: i === 0 ? "ETH" : "tBTC",
    initialValue,
    initialUnits: initialValue / price,
    initialPrice: price,
    principal: initialValue / price,
    collateral: initialValue / price,
    debt,
    equity: debt,
    basis: debt,
    loopDebt: 0,
    ltv: c.ltv[i],
    exits: [],
  };
}

export function simulate(c, options = {}) {
  const config = {
    tvl: 100000,
    path: "flat",
    policy: "harvest",
    discount: 0,
    outage: false,
    fee: 0.05,
    swapCost: 0.001,
    loopRouteCost: 0,
    bufferDays: 7,
    exitCostReserveBps: 0,
    exitLagDays: 3,
    harvestEvery: 1,
    gasPerReverse: 0,
    halfExitDay: 60,
    days: 90,
    recordDaily: false,
    ...options,
  };
  assert.ok(POLICIES.includes(config.policy));
  assert.ok(config.discount >= 0 && config.discount <= 1);
  assert.ok(config.swapCost >= 0 && config.swapCost < 1);
  assert.ok(config.fee >= 0 && config.fee <= 1);
  assert.ok(config.bufferDays >= 0 && config.exitLagDays >= 0);
  assert.ok(
    config.exitCostReserveBps >= 0 && config.exitCostReserveBps < 10000
  );
  assert.ok(Number.isInteger(config.harvestEvery) && config.harvestEvery > 0);
  assert.ok(config.days > 0 && Number.isInteger(config.days));
  assert.ok(config.halfExitDay > 0 && config.halfExitDay < config.days);
  const vaults = [
    initialVault(c, config.tvl, 0),
    initialVault(c, config.tvl, 1),
  ];
  const daily = [];
  for (const v of vaults) {
    const friction = v.equity * config.loopRouteCost;
    v.equity -= friction;
    recordCost(v, friction, "loopCosts");
    v.loopBuyVolume += v.debt;
    maintainLoop(v, c.leverage, config.loopRouteCost);
  }
  for (let day = 1; day <= config.days; day++) {
    const state = market(day, config.path, c.borrowApr);
    const prev = market(day - 1, config.path, c.borrowApr);
    const offline = config.outage && day >= 21 && day <= 50;
    for (let i = 0; i < vaults.length; i++) {
      const v = vaults[i],
        price = c.price[i] * state.factors[i];
      v.pricePnl +=
        v.collateral * c.price[i] * (state.factors[i] - prev.factors[i]);
      const earned = ((v.equity + v.loopDebt) * state.primeApr) / 365;
      const loopCost = (v.loopDebt * state.rate) / 365;
      const mainCost = (v.debt * state.rate * (1 - config.discount)) / 365;
      v.equity += earned - loopCost;
      v.loopDebt += loopCost;
      v.debt += mainCost;
      v.primeIncome += earned;
      v.loopInterest += loopCost;
      v.mainInterest += mainCost;
      assert.ok(
        v.equity > 0,
        "model needs a separate insolvency/liquidation engine at zero loop equity"
      );
      if (!offline) {
        if (config.policy === "buffer") repayReserve(v);
        if (day % config.harvestEvery === 0)
          harvest(v, price, state.rate, config);
        if (day !== config.halfExitDay && day !== config.days)
          rebalance(v, price, config);
        maintainLoop(v, c.leverage, config.loopRouteCost);
      }
      const gap = positive(v.debt - v.equity - v.reserve);
      if (gap > 1e-6) v.unfundedDays++;
      v.peakGap = Math.max(v.peakGap, gap);
      v.peakDebt = Math.max(v.peakDebt, v.debt + v.loopDebt);
      v.peakGross = Math.max(v.peakGross, v.equity + v.loopDebt);
      v.reserveDays += v.reserve;
      v.peakReserve = Math.max(v.peakReserve, v.reserve);
      if (config.recordDaily)
        daily.push({
          day,
          symbol: v.symbol,
          price,
          mainDebt: v.debt,
          loopEquity: v.equity,
          loopDebt: v.loopDebt,
          collateral: v.collateral,
          principal: v.principal,
          reserve: v.reserve,
          gap,
          collateralYieldValue:
            sellableYield(v.collateral, v.principal) * price,
          headroom: headroom(v.collateral * price, v.ltv, v.debt),
          offline,
        });
      // Requests are assumed submitted 12h before these eligible-start days.
      if (day === config.halfExitDay || day === config.days) {
        closeSlice(
          v,
          day === config.days ? 1 : 0.5,
          day,
          price,
          state.rate,
          config
        );
      }
      const expected =
        v.initialValue +
        v.pricePnl +
        v.primeIncome -
        v.loopInterest -
        v.mainInterest -
        v.fees -
        v.costs +
        v.governanceFunding -
        v.paidValue;
      const error = Math.abs(wealth(v, price) - expected);
      v.conservationError = Math.max(v.conservationError, error);
      assert.ok(
        error < Math.max(1e-6, config.tvl * 1e-10),
        `cash conservation ${error}`
      );
      assert.ok(v.collateral + 1e-12 >= v.principal);
    }
  }
  const sum = (key) => vaults.reduce((n, v) => n + v[key], 0);
  const userGainAtInitialPrices = vaults.reduce(
    (n, v) => n + (v.paidUnits - v.initialUnits) * v.initialPrice,
    0
  );
  const fundingAtInitialPrices = vaults.reduce(
    (n, v) => n + v.supportInUnits * v.initialPrice,
    0
  );
  const peakDebt = sum("peakDebt"),
    peakGross = sum("peakGross");
  const result = {
    ...config,
    snapshotBorrowApr: c.borrowApr,
    userTokenReturnPct: (100 * userGainAtInitialPrices) / config.tvl,
    unsubsidizedTokenEquivalentPct:
      (100 * (userGainAtInitialPrices - fundingAtInitialPrices)) / config.tvl,
    userGainAtInitialPrices,
    fundingAtInitialPrices,
    mainInterest: sum("mainInterest"),
    loopInterest: sum("loopInterest"),
    primeIncome: sum("primeIncome"),
    fees: sum("fees"),
    swapCosts: sum("costs"),
    reverseCosts: sum("reverseCosts"),
    reverseVolume: sum("reverseVolume"),
    reverseSwaps: sum("reverseSwaps"),
    estimatedExtraExecutionCost: sum("reverseSwaps") * config.gasPerReverse,
    governanceFunding: sum("governanceFunding"),
    minimumPrincipalSupport: sum("minimumPrincipalSupport"),
    exitDelayInterest: sum("exitDelayInterest"),
    peakGap: sum("peakGap"),
    unfundedVaultDays: sum("unfundedDays"),
    unfundedExits: sum("unfundedExits"),
    blockedRebalances: sum("blockedRebalances"),
    averageReserve: sum("reserveDays") / config.days,
    peakReserve: sum("peakReserve"),
    peakDebt,
    peakGross,
    capacityBreaches: {
      marketMint: peakDebt > c.marketMintRoom,
      primeSupply: peakGross > c.primeSupplyRoom,
      primeIsolation:
        vaults.reduce((n, v) => n + v.peakGross * (1 - 1 / c.leverage), 0) >
        c.primeIsolationRoom,
      ethSupply: config.tvl / 2 > c.ethSupplyRoom,
      btcSupply: config.tvl / 2 > c.btcSupplyRoom,
    },
    conservationError: Math.max(...vaults.map((v) => v.conservationError)),
    vaults,
    ...(config.recordDaily ? { daily } : {}),
  };
  return result;
}

export function runComparison(snapshot) {
  const c = capacity(snapshot),
    scenarios = [];
  for (const tvl of TVLS)
    for (const path of PATHS)
      for (const outage of [false, true])
        for (const discount of [0, 0.5, 1])
          for (const policy of POLICIES)
            scenarios.push(
              simulate(c, { tvl, path, outage, discount, policy })
            );
  const sensitivities = [];
  // One factor at a time around the stated default, not a disguised forecast.
  for (const tvl of [100000, 1000000])
    for (const path of PATHS)
      for (const policy of POLICIES) {
        for (const swapCost of [0, 0.005, 0.01])
          sensitivities.push({
            dimension: "swapCost",
            ...simulate(c, { tvl, path, policy, swapCost }),
          });
        for (const exitLagDays of [0, 0.5, 14])
          sensitivities.push({
            dimension: "exitLagDays",
            ...simulate(c, { tvl, path, policy, exitLagDays }),
          });
        for (const harvestEvery of [3, 7])
          sensitivities.push({
            dimension: "harvestEvery",
            ...simulate(c, { tvl, path, policy, harvestEvery }),
          });
        for (const loopRouteCost of [0.001])
          sensitivities.push({
            dimension: "loopRouteCost",
            ...simulate(c, { tvl, path, policy, loopRouteCost }),
          });
        if (policy === "buffer") {
          for (const bufferDays of [1, 3, 14, 30])
            sensitivities.push({
              dimension: "bufferDays",
              ...simulate(c, { tvl, path, policy, bufferDays }),
            });
          for (const exitCostReserveBps of [10, 20, 50])
            sensitivities.push({
              dimension: "exitCostReserve",
              ...simulate(c, {
                tvl,
                path,
                policy,
                loopRouteCost: 0.001,
                exitCostReserveBps,
              }),
            });
          for (const halfExitDay of [1, 3, 7])
            sensitivities.push({
              dimension: "earlyExit",
              ...simulate(c, {
                tvl,
                path,
                policy,
                loopRouteCost: 0.001,
                exitCostReserveBps: 10,
                halfExitDay,
              }),
            });
        }
      }
  return {
    snapshotBlock: snapshot.block,
    snapshotHash: snapshot.hash,
    calibration: c,
    assumptions: [
      "90-day deterministic economic ledger, separate from Solidity/fork execution",
      "50/50 initial ETH/tBTC USD deposits, same-token principal protected, no new entrants in path runs",
      "Actual debt INCLUDING accrued interest reduces reborrow headroom; existing 5/3 percentage-point hysteresis",
      "Per-vault attributed source sleeves, not full shared-SubLoop share and liquidation-engine behavior",
      "PRIME yield APR 6.5/4/5.5% hypothetical; borrow APR flat/bull from snapshot, bear12%, seesaw2.5/12%",
      "Rally-then-crash: day45 ETH1.5x/tBTC1.3x, day90 ETH0.3x/tBTC0.4x; switch from bull to bear rates after day45",
      "Source income first offsets accumulated source losses before harvesting above remaining cost basis",
      "5% fee after PRIME-to-collateral conversion, before Main service; only fresh yield used by harvest/buffer policies",
      "Default 10bp proportional cost each collateral conversion; 0/50/100bp sensitivities, NOT executable route quotes",
      "Source ramp/unwind execution cost zero in default comparison, independent 10bp gross-volume sensitivity",
      "Exit-cost reserve sensitivities target 10/20/50bp of gross PRIME alongside seven days Main interest, with actual modeled gross-route cost10bp",
      "Early-exit sensitivities start half the exit on day1/3/7, before a yield-funded exit buffer necessarily exists",
      "Source re-leverage maintains target HF 1.05 on service days; no real market depth, cap enforcement, liquidations or HOLLAR depeg simulation",
      "Capacity breaches flagged, not bypassed or presented as deployable exposures; sum of per-vault peaks is a conservative bound",
      "Requests 12h before day60/day90 starts; half exits first, rest second",
      "Each exiting slice bears its own extra 3-day Main-interest stress; source quote/price locked at start, no further yield; 0/0.5/14-day sensitivities",
      "Withdrawal policy requires NEW per-position principal and net-liability accounting; NOT current contract behavior",
      "Current/harvest/buffer do not sell previously compounded yield; protocol top-up needed at exit is reported separately",
      "All full-payout results condition on explicitly booked governance funding; without it short claims remain pending",
      "Token return values ETH/tBTC gains at INITIAL prices, not dollar appreciation and not annualized APY",
      "Unsubsidized token-equivalent subtracts funding converted at each exit price; it is not an authorized user haircut",
      "No holder-transfer/fairness proof or indefinite no-liquidation guarantee; principal preservation is a model constraint",
    ],
    scenarios,
    sensitivities,
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const snapshot = JSON.parse(readFileSync(process.argv[2]));
  const result = runComparison(snapshot);
  const output = process.argv[3] || "/tmp/propeller-interest-policies.json";
  writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
  const fields = [
    "tvl",
    "path",
    "outage",
    "discount",
    "policy",
    "swapCost",
    "exitLagDays",
    "bufferDays",
    "exitCostReserveBps",
    "harvestEvery",
    "userTokenReturnPct",
    "unsubsidizedTokenEquivalentPct",
    "mainInterest",
    "loopInterest",
    "fees",
    "swapCosts",
    "reverseVolume",
    "reverseSwaps",
    "governanceFunding",
    "minimumPrincipalSupport",
    "unfundedExits",
    "unfundedVaultDays",
    "blockedRebalances",
    "averageReserve",
    "peakGap",
    "peakDebt",
  ];
  writeFileSync(
    output.replace(/\.json$/, ".csv"),
    [
      fields.join(","),
      ...result.scenarios.map((s) => fields.map((k) => s[k]).join(",")),
    ].join("\n") + "\n"
  );
  console.log(
    JSON.stringify(
      {
        output,
        snapshotBlock: result.snapshotBlock,
        scenarios: result.scenarios.length,
        sensitivities: result.sensitivities.length,
        calibration: result.calibration,
        baseline: result.scenarios
          .filter((s) => s.tvl === 100000 && !s.outage && s.discount === 0)
          .map((s) =>
            Object.fromEntries(
              fields
                .filter(
                  (k) =>
                    ![
                      "tvl",
                      "outage",
                      "discount",
                      "swapCost",
                      "bufferDays",
                      "harvestEvery",
                      "exitLagDays",
                    ].includes(k)
                )
                .map((k) => [k, s[k]])
            )
          ),
      },
      null,
      2
    )
  );
}
