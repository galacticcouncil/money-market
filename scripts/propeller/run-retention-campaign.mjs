// Serial Forge runs only: sharing an output/cache directory concurrently is unsafe.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  readFileSync,
  writeFileSync,
  openSync,
  closeSync,
  mkdirSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
const root = fileURLToPath(new URL("../../", import.meta.url));
const output = resolve(process.argv[2] || "/tmp/propeller-retention-20260923");
const loopCost = Number(process.env.RETENTION_LOOP_COST_BPS ?? 25);
const swapCost = Number(process.env.RETENTION_SWAP_COST_BPS ?? 85);
assert.ok(Number.isInteger(loopCost) && loopCost >= 0 && loopCost <= 25);
assert.ok(Number.isInteger(swapCost) && swapCost >= 0 && swapCost <= 100);
mkdirSync(output, { recursive: true });
const results = [];
for (const ceiling of [25, 50, 100]) {
  const log = resolve(output, `forge-${ceiling}bps.log`),
    fd = openSync(log, "w");
  try {
    execFileSync(
      "forge",
      [
        "test",
        "--offline",
        "--evm-version",
        "london",
        "--match-contract",
        "MainDebtCampaignTest",
        "--match-test",
        "test_campaign",
        "-vv",
      ],
      {
        cwd: resolve(root, "propeller-vault"),
        stdio: ["ignore", fd, fd],
        timeout: 900000,
        env: {
          ...process.env,
          RUN_MAIN_DEBT_CAMPAIGN: "true",
          FOUNDRY_GAS_LIMIT: "1000000000000",
          CAMPAIGN_LOOP_COST_BPS: String(loopCost),
          CAMPAIGN_SWAP_COST_BPS: String(swapCost),
          CAMPAIGN_CEILING_BPS: String(ceiling),
        },
      }
    );
  } finally {
    closeSync(fd);
  }
  const dir = resolve(output, `${ceiling}bps`);
  execFileSync(
    process.execPath,
    [
      resolve(root, "scripts/propeller/report-main-debt-campaign.mjs"),
      log,
      dir,
    ],
    { stdio: "inherit" }
  );
  const summary = JSON.parse(
    readFileSync(resolve(dir, "contract-campaign-summary.json"))
  );
  assert.deepEqual(summary.mainGridCosts, [
    { loopCostBps: loopCost, swapCostBps: swapCost, slippageBps: ceiling },
  ]);
  results.push({
    ceilingBps: ceiling,
    aggregate: summary.aggregate,
    oneMillion: summary.oneMillionMainCases,
    logSha256: summary.logSha256,
  });
  console.log("RETENTION CAMPAIGN COMPLETE", ceiling);
}
writeFileSync(
  resolve(output, "comparison.json"),
  JSON.stringify(
    {
      scope: `1110 actual-contract 90-day cases, mocked Aave/router boundary. Conditional ${loopCost}bp loop and ${swapCost}bp collateral-route costs, not currently executable entry or future liquidity assurance.`,
      grid: "Each ceiling runs the full six-TVL/5-path/3-discount/2-outage main grid plus 190 sensitivities. Sensitivity rows override selected main-grid settings.",
      results,
    },
    null,
    2
  ) + "\n"
);
