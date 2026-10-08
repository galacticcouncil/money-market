import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { resolve } from "node:path";
const dir = resolve(
  process.argv[2] || "propeller-vault/docs/evidence/prime-validation-2026-09-23"
);
const inputs = Object.fromEntries(
  ["market", "solana", "hydration", "history", "calibration", "analysis"].map(
    (k) => [k, `/tmp/propeller-prime-validation-${k}-20260923.json`]
  )
);
inputs.checkedOracle = "/tmp/propeller-prime-checked-oracle-20260923.json";
const j = Object.fromEntries(
  Object.entries(inputs).map(([k, f]) => [k, JSON.parse(readFileSync(f))])
);
assert.deepEqual(j.solana.errors, {});
assert.deepEqual(j.hydration.errors, {});
assert.equal(j.solana.reference.fresh, true);
assert.equal(
  j.hydration.receiver.oracles.toLowerCase(),
  j.hydration.oracles.receiverTarget.address.toLowerCase()
);
assert.equal(j.checkedOracle.checks["100013124"][0], false);
assert.equal(j.checkedOracle.checks["106081891"][0], true);
assert.equal(j.history.activityCoverage.exhausted, true);
assert.equal(j.analysis.providerCommitmentVerified, false);
const events = j.hydration.receiverTargetHistory;
assert.ok(events.length >= 2);
assert.equal(
  events.at(-1).roundId,
  j.hydration.oracles.receiverTarget.latestRoundData[0]
);
const gaps = events
  .slice(1)
  .map((e, i) => Number(e.timestamp) - Number(events[i].timestamp));
const result = {
  date: "2026-09-23",
  scope: "RC evidence, not production configuration or funding approval",
  inputs: Object.fromEntries(
    Object.entries(inputs).map(([k, f]) => [
      k,
      {
        file: `${k}.json`,
        sha256: createHash("sha256").update(readFileSync(f)).digest("hex"),
      },
    ])
  ),
  pricing: {
    active: j.hydration.oracles.active,
    replacement: j.hydration.oracles.receiverTarget,
    guard: j.checkedOracle.checks,
    hastra: j.solana.reference,
    obsoleteScope: j.solana.relaySource,
    receiverUpdateHistory: {
      events: events.length,
      first: events[0],
      last: events.at(-1),
      minGapSeconds: Math.min(...gaps),
      maxGapSeconds: Math.max(...gaps),
    },
    conclusion:
      "Replacement price agrees closely with Hastra and rejects obsolete Scope, but production Aave/pool peg still use the manual source. Operational freshness and source attestation must be approved before switching.",
  },
  replenishment: {
    liquidity: j.analysis.liquidity,
    bridge: j.analysis.bridge,
    redemption: j.analysis.redemption,
    history: { ...j.analysis.history, observedDaily: undefined },
    ramp: j.analysis.ramp,
    scenarios: j.analysis.scenarios,
    conclusion:
      "Mint/bridge infrastructure exists; funded, profitable and timely replenishment at launch scale remains uncommitted. Current one-shot pool143-to-pool110 refill quotes have negative edge versus Hastra mint cost before extra costs.",
  },
  limitations: j.analysis.limitations,
};
mkdirSync(dir, { recursive: true });
for (const [k, f] of Object.entries(inputs))
  copyFileSync(f, resolve(dir, `${k}.json`));
writeFileSync(
  resolve(dir, "summary.json"),
  JSON.stringify(result, null, 2) + "\n"
);
console.log(
  JSON.stringify(
    {
      pricing: result.pricing.conclusion,
      replenishment: result.replenishment.conclusion,
      updateHistory: result.pricing.receiverUpdateHistory,
    },
    null,
    2
  )
);
