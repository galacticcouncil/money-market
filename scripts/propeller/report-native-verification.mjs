// Archive native execution evidence without treating a fork rehearsal as approval.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const [resultPath, readinessPath, regressionPath, forkPath, verificationPath, outputPath] = process.argv.slice(2);
assert.ok(outputPath, "usage: node report-native-verification.mjs result.json readiness.log regression.log fork.log verification.log output.json");
const paths = { nativeResult: resultPath, readiness: readinessPath, regression: regressionPath,
  aaveFork: forkPath, artifactVerification: verificationPath };
const inputs = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, readFileSync(path, "utf8")]));
const r = JSON.parse(inputs.nativeResult);
assert.equal(r.status, "native-multi-user-multi-vault-campaign-passed");
for (const key of ["deployedCodeMatchesLocalArtifacts", "proxyImplementationSlots",
  "nativeAccruedInterestServicedByHarvest", "nativeFourPublicPositionsPaidInFull",
  "exitOwnershipAndPendingSourceClaims", "constructorHelperMatchesArtifact"]) {
  assert.equal(r.checks[key], true, `missing native proof: ${key}`);
}
assert.match(inputs.artifactVerification, /FINAL VERIFICATION PASS/);
assert.equal(r.campaignPayouts.length, 4);
for (const payout of r.campaignPayouts) {
  assert.equal(payout.paid, payout.promised);
  assert.ok(BigInt(payout.paid) >= BigInt(payout.deposited));
}
const counts = log => {
  const match = log.match(/(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)/);
  assert.ok(match, "missing Foundry summary");
  assert.equal(Number(match[2]), 0);
  return { passed: Number(match[1]), failed: Number(match[2]), skipped: Number(match[3]), total: Number(match[4]) };
};
const readiness = inputs.readiness.match(/(\d+)\/(\d+) checks passed, (\d+) FAILED/);
assert.ok(readiness, "missing readiness summary (this fixture is not production-ready)");
const bufferSection = inputs.readiness.split("O. Operating buffers")[1]?.split("R. Custody dust protection")[0];
assert.ok(bufferSection && !bufferSection.includes("FAIL"));
const bufferPasses = [...bufferSection.matchAll(/PASS/g)].length;
assert.equal(bufferPasses, 16);
const failures = [...inputs.readiness.matchAll(/^  - (.+)$/gm)].map(match => match[1]);
assert.equal(failures.length, Number(readiness[3]));
const output = {
  scope: "Local Chopsticks rehearsal only; no production deployment or configuration approval.",
  baseCommit: r.baseCommit, branch: r.branch, verifiedUncommittedBuild: r.uncommitted,
  inputSha256: Object.fromEntries(Object.entries(inputs).map(([key, value]) =>
    [key, createHash("sha256").update(value).digest("hex")])),
  tests: { regression: counts(inputs.regression), aaveFork: counts(inputs.aaveFork) },
  readiness: { passed: Number(readiness[1]), total: Number(readiness[2]), failed: Number(readiness[3]),
    operatingBufferChecksPassed: bufferPasses, failures,
    explanation: "Development governance/owner stand-ins and absent synthetic Substrate registry mapping remain failures, not waived production checks." },
  native: {
    status: r.status, rpc: r.rpc, upstream: r.upstream,
    fork: { block: r.fork.block, hash: r.fork.hash, runtime: r.fork.runtime.specVersion, chainId: r.fork.chainId },
    verifiedThroughBlock: r.verifiedThroughBlock, checks: r.checks,
    market: r.market, addresses: r.addresses, overrides: r.overrides,
    deployments: r.deployments, calls: r.calls,
    receiptCaveat: "Every receipt checked when mined; pruned receipt lookups are marked unavailable, not reverified. Final live code and bindings were rechecked.",
    testOnlyPolicy: r.testOnlyPolicy, entryFloorFinding: r.entryFloorFinding,
    operatingBootstrap: r.operatingBootstrap, roundingPolicies: r.roundingPolicies,
    preHarvest: r.campaignPreHarvest, collateralPayouts: r.campaignPayouts,
    unpaidSourceClaims: r.finalBufferExits,
    unpaidSourceClaimTotalWei: r.finalBufferExits.reduce((sum, p) => sum + BigInt(p.unpaidSourceClaim), 0n).toString(),
    timeAdvances: "One day before harvest; seven days after exit requests. This is not a native 90-day path.",
    externalSupport: {
      primeDonatedToSource: "100 PRIME; fixture for harvest execution, not earned yield",
      hollarBootstrap: "1000 HOLLAR per vault, from a fork-only donor borrow",
      hollarSourceSupport: "10 HOLLAR before second seed, 50 HOLLAR before public entries, 100 HOLLAR during recovery",
      hollarActiveRecovery: "100 HOLLAR per vault via fundPosition(0), allocated before all four exits start",
      warning: "Collateral gains and HOLLAR payouts include donated capital; neither is an APY estimate.",
    },
    limitations: r.campaignLimitations, infrastructureCaveat: r.infrastructureCaveat,
  },
};
writeFileSync(outputPath, JSON.stringify(output, null, 2) + "\n");
console.log(JSON.stringify({ tests: output.tests, readiness: output.readiness,
  nativeStatus: output.native.status, unpaidSourceClaimTotalWei: output.native.unpaidSourceClaimTotalWei }, null, 2));
