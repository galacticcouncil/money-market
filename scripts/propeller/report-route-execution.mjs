// Archive measured evidence; no failed stage can be silently promoted to a pass.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
const { values } = parseArgs({
  options: {
    "run-dir": { type: "string", default: "/tmp" },
    output: { type: "string" },
  },
});
assert.ok(
  values.output,
  "usage: report-route-execution.mjs --run-dir /tmp --output evidence-directory"
);
const root = fileURLToPath(new URL("../../", import.meta.url)),
  dir = resolve(values.output);
const path = (name) => resolve(values["run-dir"], `propeller-${name}-20260923`);
const json = (file) => JSON.parse(readFileSync(file));
const hash = (file) =>
  createHash("sha256").update(readFileSync(file)).digest("hex");
const baseline = json(path("route-native") + ".json"),
  conditional = json(path("route-conditional") + ".json");
assert.equal(baseline.status, "native-entry-blocked-by-strict-slippage");
assert.equal(baseline.checks.strictSlippageNotWidened, true);
assert.equal(
  conditional.status,
  "native-multi-user-multi-vault-campaign-passed"
);
assert.ok(conditional.referenceScenario);
assert.equal(conditional.verifiedPolicy.slippagePpm, 10000);
assert.equal(conditional.checks.exitOwnershipAndPendingSourceClaims, true);
assert.equal(conditional.nativeResize.passed, true);
assert.equal(conditional.nativeResize.ltvRestored, true);
assert.equal(conditional.finalBufferExits.length, 4);
for (const exit of conditional.finalBufferExits)
  assert.equal(exit.unpaidSourceClaim, "0");
assert.equal(conditional.nativeResize.latePayouts.length, 4);
for (const payout of conditional.nativeResize.latePayouts)
  assert.ok(BigInt(payout.paid) > 0n);
assert.equal(
  conditional.verifiedPolicy.deployTrancheWei,
  "1000000000000000000000"
);
assert.equal(conditional.verifiedPolicy.unwindTranchePrimeUnits, "900000000");
assert.equal(conditional.campaignPayouts.length, 4);
for (const p of conditional.campaignPayouts) {
  assert.equal(p.paid, p.promised);
  assert.ok(BigInt(p.paid) >= BigInt(p.deposited));
}
const logFiles = {
  regression: path("routes-regression") + ".log",
  calibration: path("route-calibration-tests") + ".log",
  adapterUnit: path("hydra-adapter-unit") + ".log",
  adapterConfig: path("hydra-adapter-config") + ".log",
  baselineVerification: path("route-verify") + ".log",
  conditionalVerification: path("route-conditional-verify") + ".log",
};
const count = (file) => {
  const log = readFileSync(file, "utf8");
  const match = log.match(/(\d+) tests passed, (\d+) failed, (\d+) skipped/);
  assert.ok(match, `missing test summary: ${file}`);
  assert.equal(Number(match[2]), 0);
  return { passed: Number(match[1]), failed: 0, skipped: Number(match[3]) };
};
const calibrationLog = readFileSync(logFiles.calibration, "utf8");
assert.match(calibrationLog, /# tests 8\b/);
assert.match(calibrationLog, /# pass 8\b/);
assert.match(calibrationLog, /# fail 0\b/);
assert.match(calibrationLog, /# skipped 0\b/);
for (const key of ["baselineVerification", "conditionalVerification"])
  assert.match(
    readFileSync(logFiles[key], "utf8"),
    /FINAL ARTIFACT VERIFICATION PASS/
  );
const previous = json(
  resolve(
    root,
    "propeller-vault/docs/evidence/main-debt-2026-09-22/contract-campaign-summary.json"
  )
);
const productionArtifacts = {};
for (const name of [
  "CollateralVault",
  "SubLoop",
  "PropellerMainDebt",
  "PropellerFeeController",
  "Harvester",
  "CompoundLogic",
  "PropellerDiscount",
]) {
  const a = json(resolve(root, `propeller-vault/out/${name}.sol/${name}.json`));
  const code = Buffer.from(a.deployedBytecode.object.replace(/^0x/, ""), "hex");
  const digest = createHash("sha256").update(code).digest("hex");
  assert.equal(
    digest,
    previous.artifacts[name].templateSha256,
    `${name}: changed production template`
  );
  productionArtifacts[name] = {
    runtimeBytes: code.length,
    templateSha256: digest,
    unchanged: true,
  };
}
mkdirSync(dir, { recursive: true });
const archive = (source, name) => {
  const target = resolve(dir, name);
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(source, target);
};
for (const [name, file] of Object.entries(logFiles))
  archive(file, `logs/${name}.log`);
for (const [name, source] of Object.entries({
  "native-baseline.json": path("route-native") + ".json",
  "native-conditional.json": path("route-conditional") + ".json",
  "market.json": path("route-market") + ".json",
  "prime-reference.json": path("route-prime-reference") + ".json",
  "calibration.json": path("route-calibration") + ".json",
}))
  archive(source, name);
const profiles = [];
for (const [folder, name] of [
  ["retention-low-cost", "cost-10bps"],
  ["retention", "cost-25bps"],
]) {
  const source = path(folder),
    comparison = json(resolve(source, "comparison.json"));
  assert.equal(comparison.results.length, 3);
  for (const ceiling of [25, 50, 100]) {
    const summary = json(
      resolve(source, `${ceiling}bps/contract-campaign-summary.json`)
    );
    assert.equal(summary.aggregate.cases, 370);
    assert.equal(
      summary.logSha256,
      hash(resolve(source, `forge-${ceiling}bps.log`))
    );
    assert.deepEqual(count(resolve(source, `forge-${ceiling}bps.log`)), {
      passed: 8,
      failed: 0,
      skipped: 0,
    });
    archive(
      resolve(source, `forge-${ceiling}bps.log`),
      `${name}/${ceiling}bps/forge.log`
    );
    for (const file of [
      "contract-campaign.csv",
      "contract-campaign-summary.json",
    ])
      archive(
        resolve(source, `${ceiling}bps/${file}`),
        `${name}/${ceiling}bps/${file}`
      );
  }
  archive(resolve(source, "comparison.json"), `${name}/comparison.json`);
  profiles.push({ name, ...comparison });
}
const snapshot = json(path("route-market") + ".json");
const report = {
  scope:
    "Local research; unchanged-market entry blocked. Conditional oracle-update lifecycle and LTV resize passed. Not a launch approval.",
  fork: {
    upstream: baseline.upstream,
    block: baseline.fork.block,
    hash: baseline.fork.hash,
    runtime: baseline.fork.runtime.specVersion,
  },
  adapter: {
    repository: "https://github.com/galacticcouncil/aave-debt-swap",
    commit: "ddc883efe18ddb6bb90a40d370f3280f51bda0d8",
    deployment: baseline.deployments.find((x) => x.label === "HydraAugustus"),
    caveats: [
      "Propeller uses sell only; buy amount order is incompatible with ISwapper.buy.",
      "Dispatch allowances remain after the trade. Empty custody was checked; allowance cleanup was not claimed.",
      "Not an independent security audit.",
    ],
  },
  tests: {
    regression: count(logFiles.regression),
    adapterSwap: count(logFiles.adapterUnit),
    adapterConfiguration: count(logFiles.adapterConfig),
    calibration: {
      passed: 8,
      failed: 0,
      skipped: 0,
      exactNativeSdkMatches: baseline.routeCalibration.rows.filter(
        (q) =>
          [43, 1043, 222].includes(q.input) &&
          [43, 1043, 222].includes(q.output) &&
          q.outputAmount
      ).length,
    },
    contractScenarioExecutions: profiles.reduce(
      (total, profile) =>
        total + profile.results.reduce((n, r) => n + r.aggregate.cases, 0),
      0
    ),
  },
  observed: {
    entryAllowed: false,
    quotes: baseline.routeCalibration.rows.length,
    quotedSuccessfully: baseline.routeCalibration.rows.filter(
      (x) => x.outputAmount
    ).length,
    submittedSwaps: baseline.routeCalibration.executions.filter(
      (x) => x.submitted
    ).length,
    primeOracleLastUpdated: new Date(
      Number(baseline.routeCalibration.primeOracleRound[3]) * 1000
    ).toISOString(),
    primeOracleAgeDays:
      (Number(snapshot.blockTimestampMs) / 1000 -
        Number(baseline.routeCalibration.primeOracleRound[3])) /
      86400,
    slippagePpm: baseline.verifiedPolicy.slippagePpm,
  },
  conditional: {
    referenceScenario: conditional.referenceScenario,
    lifecyclePassed: true,
    exactCollateralPayouts: conditional.campaignPayouts,
    nativeResize: conditional.nativeResize,
    policy: conditional.verifiedPolicy,
    finalExits: conditional.finalBufferExits,
    verifiedThroughBlock: conditional.verifiedThroughBlock,
    limitation:
      "Donated PRIME tests harvest, explicit HOLLAR support funds recovery; neither demonstrates organic APY. Oracle update assumes wYLDS=$1. Not native 90-day or converged-peg lifecycle coverage.",
  },
  productionArtifacts,
  profiles,
  inputSha256: Object.fromEntries(
    Object.entries(logFiles).map(([k, v]) => [k, hash(v)])
  ),
  remaining: [
    "Authoritative PRIME/USD reference and freshness policy",
    "Executable entry after pool-peg convergence and finite replenishment",
    "Deposit/admission limits and bounded harvest sizes",
    "Independent review, production wiring and launch/backstop budgets",
  ],
};
writeFileSync(
  resolve(dir, "summary.json"),
  JSON.stringify(report, null, 2) + "\n"
);
console.log(
  JSON.stringify(
    {
      tests: report.tests,
      observed: report.observed,
      resizePassed: conditional.nativeResize.passed,
    },
    null,
    2
  )
);
