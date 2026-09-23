// Evidence for compatibility preparation only, not an implemented migration.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const [regressionPath, nodeTestsPath, baseLayoutPath, probeLayoutPath, outputPath] = process.argv.slice(2);
assert.ok(outputPath, "usage: node report-source-upgrades.mjs regression.log node-tests.tap base-layout.json probe-layout.json output.json");
const paths = { regression: regressionPath, storageTests: nodeTestsPath,
  baseLayout: baseLayoutPath, probeLayout: probeLayoutPath };
const inputs = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, readFileSync(path, "utf8")]));
const counts = inputs.regression.match(/(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)/);
assert.ok(counts, "missing Foundry summary");
assert.equal(Number(counts[2]), 0);
const names = [...inputs.regression.matchAll(/^\[PASS\] (test_upgrade\w+)\(/gm)].map(m => m[1]);
assert.equal(new Set(names).size, 7, "missing focused upgrade tests");
const nodeCount = Number(inputs.storageTests.match(/^# tests (\d+)$/m)?.[1]);
assert.equal(nodeCount, 8, "capture individual checker tests, not just a file wrapper");
assert.match(inputs.storageTests, /^# pass 8$/m);
assert.match(inputs.storageTests, /^# fail 0$/m);
assert.match(inputs.storageTests, /^# skipped 0$/m);
const baseLayout = JSON.parse(inputs.baseLayout);
const probeLayout = JSON.parse(inputs.probeLayout);
assert.equal(baseLayout.compatibleStoragePrefix, true);
assert.equal(probeLayout.compatibleStoragePrefix, true);
assert.equal(probeLayout.preservedEntries, baseLayout.preservedEntries);
assert.equal(probeLayout.appendedEntries, 1);
const root = fileURLToPath(new URL("../../propeller-vault/", import.meta.url));
const previous = JSON.parse(readFileSync(join(root, "docs/evidence/main-debt-2026-09-22/contract-campaign-summary.json"), "utf8"));
const sha = value => createHash("sha256").update(value).digest("hex");
const contracts = ["CollateralVault", "SubLoop", "PropellerMainDebt", "PropellerFeeController",
  "Harvester", "CompoundLogic", "PropellerDiscount"];
const productionArtifacts = Object.fromEntries(contracts.map(name => {
  const artifact = JSON.parse(readFileSync(join(root, `out/${name}.sol/${name}.json`), "utf8"));
  const code = Buffer.from(artifact.deployedBytecode.object.replace(/^0x/, ""), "hex");
  assert.equal(sha(code), previous.artifacts[name].templateSha256, `production bytecode changed: ${name}`);
  return [name, { runtimeBytes: code.length, templateSha256: sha(code), unchanged: true }];
}));
const output = {
  scope: "Local source-upgrade compatibility preparation; no strategy rotation, production upgrade or migration approval.",
  solidity: { passed: Number(counts[1]), failed: 0, skipped: Number(counts[3]), total: Number(counts[4]),
    upgradeCases: names, skippedSetups: ["ProtocolFeesForkTest", "PropellerDiscountForkTest", "VerityParityTest"] },
  storage: { testsPassed: nodeCount, baseLayout, probeLayout,
    baselineSha256: sha(readFileSync(join(root, "docs/evidence/source-upgrades-2026-09-23/subloop-storage.json"))) },
  productionArtifacts,
  inputSha256: Object.fromEntries(Object.entries(inputs).map(([key, value]) => [key, sha(value)])),
  limitations: [
    "Real Propeller contracts with mock Aave/router; test-only upgrade candidates, not a second yield strategy.",
    "The broken-counter probe is allowed to install; its settlement failure demonstrates why governance authorization is not semantic validation.",
    "No fresh native or 90-day campaign rerun for this test/documentation-only revision; production bytecode matches the prior rehearsal.",
    "Existing strict-entry, production-adapter, funding and liquidity release gates remain open.",
    "The layout gate freezes existing gaps and compiler version; it does not prove assembly-slot, economic or migration safety.",
  ],
};
writeFileSync(outputPath, JSON.stringify(output, null, 2) + "\n");
console.log(JSON.stringify({ solidity: output.solidity, storageTestsPassed: nodeCount,
  preservedStorageEntries: baseLayout.preservedEntries, unchangedProductionContracts: contracts.length }, null, 2));
