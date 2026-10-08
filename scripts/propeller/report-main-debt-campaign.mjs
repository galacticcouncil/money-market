// Summarize successful Foundry contract executions; never synthesize missing cases.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";

const [logPath, outputDirectory] = process.argv.slice(2);
assert.ok(
  logPath && outputDirectory,
  "usage: node report-main-debt-campaign.mjs forge.log output-directory"
);
const log = readFileSync(logPath, "utf8");
assert.ok(!log.includes("[FAIL"), "failed contract campaign");
assert.match(log, /8 tests passed, 0 failed, 0 skipped/);
const columns = [
  "tvl",
  "path",
  "outage",
  "discountBps",
  "dimension",
  "swapCostBps",
  "loopCostBps",
  "slippageBps",
  "incentiveMode",
  "exitLagSeconds",
  "harvestEveryDays",
  "halfExitDay",
  "mainInterestWei",
  "loopInterestWei",
  "incentiveWei",
  "recoveryWei",
  "peakDebtWei",
  "hollarSoldWei",
  "hollarBoughtWei",
  "floorMisses",
  "liquidations",
  "ethReturnBps",
  "btcReturnBps",
  "surplusPaidWei",
  "residualSourceClaimWei",
  "recoveryLiquidityWei",
];
const values = [...log.matchAll(/^\s*CONTRACT_CASE,([0-9,]+)$/gm)].map(
  (match) => match[1].split(",")
);
assert.equal(values.length, 370);
const keys = new Set();
const rows = values.map((values) => {
  assert.equal(values.length, columns.length);
  const row = Object.fromEntries(
    columns.map((column, i) => [column, values[i]])
  );
  const key = [
    row.tvl,
    row.path,
    row.outage,
    row.discountBps,
    row.dimension,
  ].join("/");
  assert.ok(!keys.has(key), `duplicate ${key}`);
  keys.add(key);
  return row;
});
const tvls = [100_000, 500_000, 1_000_000, 10_000_000, 50_000_000, 100_000_000];
for (const tvl of tvls)
  for (let path = 0; path < 5; path++) {
    for (let outage = 0; outage < 2; outage++)
      for (const discount of [0, 5000, 10000]) {
        assert.ok(keys.has([tvl, path, outage, discount, 0].join("/")));
      }
  }
for (const tvl of [100_000, 1_000_000])
  for (let path = 0; path < 5; path++) {
    for (let dimension = 1; dimension <= 19; dimension++) {
      assert.ok(keys.has([tvl, path, 0, 0, dimension].join("/")));
    }
  }
const usd = (value) => Number(BigInt(value)) / 1e18;
const summarize = (subset) => ({
  cases: subset.length,
  casesWithMaterialRecovery: subset.filter((r) => usd(r.recoveryWei) > 0.01)
    .length,
  casesWithResidualSourceClaims: subset.filter(
    (r) => usd(r.residualSourceClaimWei) > 0.01
  ).length,
  maxRecoveryPctTvl: Math.max(
    ...subset.map((r) => (usd(r.recoveryWei) / Number(r.tvl)) * 100)
  ),
  casesWithRecoveryLiquidity: subset.filter(
    (r) => usd(r.recoveryLiquidityWei) > 0.01
  ).length,
  maxRecoveryLiquidityPctTvl: Math.max(
    ...subset.map((r) => (usd(r.recoveryLiquidityWei) / Number(r.tvl)) * 100)
  ),
  maxIncentivePctTvl: Math.max(
    ...subset.map((r) => (usd(r.incentiveWei) / Number(r.tvl)) * 100)
  ),
  maxPeakDebtToTvl: Math.max(
    ...subset.map((r) => usd(r.peakDebtWei) / Number(r.tvl))
  ),
  floorMisses: subset.reduce((sum, r) => sum + Number(r.floorMisses), 0),
  liquidations: subset.reduce((sum, r) => sum + Number(r.liquidations), 0),
  minEthReturnBps: Math.min(...subset.map((r) => Number(r.ethReturnBps))),
  minBtcReturnBps: Math.min(...subset.map((r) => Number(r.btcReturnBps))),
});
const output = {
  campaign: "MainDebtCampaignTest",
  logSha256: createHash("sha256").update(log).digest("hex"),
  days: 90,
  collateralWeights: { ETH: 0.5, tBTC: 0.5 },
  paths: ["flat", "bull", "bear", "seesaw", "rally-crash"],
  scope:
    "Actual Propeller contracts; explicit mocked Aave accrual/router/liquidation. Not native pool capacity proof.",
  principal:
    "All public collateral claims settled after explicit recovery; deposited-token principal asserted with zero tolerance.",
  returns:
    "Realized collateral-token gains for partial plus final exits, not annualized APY. HOLLAR surplus payouts are separate. Incentive cases include externally repaid debt.",
  funding:
    "No operating bootstrap. Recovery includes entry friction, negative source carry, final shortfalls and separately measured exit liquidity bridges after 1500 settlement calls. Bridged source receivables remain owned. Day-30 incentives are separately measured, not organic yield.",
  incentiveModes: {
    0: "none",
    1: "Main accrued interest",
    2: "Main debt",
    3: "PRIME-loop debt",
  },
  slippage:
    "Test ceilings and modeled fills are recorded in each row, not production approvals. Explicit 10/25/50/100bp sensitivities remain distinct from the main grid; no automatic widening.",
  mainGridCosts: [
    ...new Set(
      rows
        .filter((r) => r.dimension === "0")
        .map((r) => [r.loopCostBps, r.swapCostBps, r.slippageBps].join("/"))
    ),
  ].map((key) => {
    const [loopCostBps, swapCostBps, slippageBps] = key.split("/").map(Number);
    return { loopCostBps, swapCostBps, slippageBps };
  }),
  aggregate: summarize(rows),
  artifacts: Object.fromEntries(
    [
      ["CollateralVault", "CollateralVault"],
      ["SubLoop", "SubLoop"],
      ["Harvester", "Harvester"],
      ["PropellerFeeController", "PropellerFeeController"],
      ["PropellerDiscount", "PropellerDiscount"],
      ["PropellerMainDebt", "PropellerMainDebt"],
      ["CompoundLogic", "CompoundLogic"],
      ["MockPool", "MockPool"],
      ["MockDispatch", "MockDispatch"],
      ["MockDiscountDebtToken", "MockDiscount"],
    ].map(([name, file]) => {
      const a = JSON.parse(
        readFileSync(
          new URL(
            `../../propeller-vault/out/${file}.sol/${name}.json`,
            import.meta.url
          )
        )
      );
      const code = Buffer.from(
        a.deployedBytecode.object.replace(/^0x/, ""),
        "hex"
      );
      return [
        name,
        {
          runtimeBytes: code.length,
          templateSha256: createHash("sha256").update(code).digest("hex"),
          immutableReferences: a.deployedBytecode.immutableReferences ?? {},
        },
      ];
    })
  ),
  byTvl: Object.fromEntries(
    tvls.map((tvl) => [
      tvl,
      summarize(rows.filter((r) => Number(r.tvl) === tvl)),
    ])
  ),
  oneMillionMainCases: rows
    .filter((r) => r.tvl === "1000000" && r.dimension === "0")
    .map((r) => ({
      path: Number(r.path),
      outage: r.outage === "1",
      discountBps: Number(r.discountBps),
      mainInterest: usd(r.mainInterestWei),
      loopInterest: usd(r.loopInterestWei),
      incentive: usd(r.incentiveWei),
      recovery: usd(r.recoveryWei),
      peakDebt: usd(r.peakDebtWei),
      hollarSold: usd(r.hollarSoldWei),
      hollarBought: usd(r.hollarBoughtWei),
      ethReturnBps: Number(r.ethReturnBps),
      btcReturnBps: Number(r.btcReturnBps),
      surplusPaid: usd(r.surplusPaidWei),
      residualSourceClaim: usd(r.residualSourceClaimWei),
      recoveryLiquidity: usd(r.recoveryLiquidityWei),
    })),
};
mkdirSync(outputDirectory, { recursive: true });
writeFileSync(
  resolve(outputDirectory, "contract-campaign.csv"),
  [columns.join(","), ...values.map((v) => v.join(","))].join("\n") + "\n"
);
writeFileSync(
  resolve(outputDirectory, "contract-campaign-summary.json"),
  JSON.stringify(output, null, 2) + "\n"
);
console.log(JSON.stringify(output.aggregate, null, 2));
