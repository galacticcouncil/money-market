// Compact companion evidence. These are off-chain models, not contract execution.
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import assert from "node:assert/strict";

const [prefix, output] = process.argv.slice(2);
assert.ok(prefix && output, "usage: node report-model-reruns.mjs input-prefix output.json");
const sources = {};
function read(suffix) {
  const body = readFileSync(`${prefix}${suffix}.json`);
  sources[suffix] = createHash("sha256").update(body).digest("hex");
  return JSON.parse(body);
}
const policy = read("policy-model-rerun");
const pressure = read("pressure-rerun");
const peg = read("peg-rerun");
function coupled(suffix) {
  const { daily, baseline, ...result } = read(suffix);
  return result;
}
const result = {
  scope: "Off-chain economic controls and finite-liquidity models, distinct from the real-contract campaign.",
  snapshotBlock: policy.snapshotBlock,
  snapshotHash: policy.snapshotHash,
  policy: {
    scenarios: policy.scenarios.length,
    sensitivities: policy.sensitivities.length,
    maxAbsoluteConservationError: Math.max(...[...policy.scenarios, ...policy.sensitivities].map(r => Math.abs(r.conservationError))),
  },
  pressure: {
    scenarios: pressure.scenarios.length,
    entries: pressure.entries,
    capacity: pressure.capacity,
    hsm: pressure.hsm,
    noRefillEntryAtOnePercent: pressure.noRefillEntryAtOnePercent,
  },
  peg: {
    entryScenarios: peg.scenarios.length,
    marketPaths: peg.marketPaths.length,
    sensitivities: peg.sensitivities.length,
    current: peg.current,
  },
  coupledWithoutBuyer: coupled("coupled-base-rerun"),
  coupledWithBuyer: coupled("coupled-funded-rerun"),
  sourceSha256: sources,
};
assert.equal(Number(pressure.snapshotBlock), Number(policy.snapshotBlock));
assert.equal(Number(peg.block), Number(policy.snapshotBlock));
writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
console.log(output);
