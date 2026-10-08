// Archive final checks without treating skipped or failed research replays as passes.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256 } from "viem";

const output = resolve(
  process.argv[2] || "propeller-vault/docs/evidence/rc1-2026-09-23"
);
mkdirSync(output, { recursive: true });
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const json = (file) => JSON.parse(readFileSync(file));
const archive = (name, source) => {
  const bytes = readFileSync(source);
  const normalized =
    bytes
      .toString("utf8")
      .replace(/[ \t]+$/gm, "")
      .trimEnd() + "\n";
  writeFileSync(resolve(output, `${name}.log`), normalized);
  return {
    file: `${name}.log`,
    sha256: hash(normalized),
    rawInputSha256: hash(bytes),
  };
};
const counts = (log) =>
  Object.fromEntries(
    ["tests", "pass", "fail", "skipped"].map((key) => {
      const value = log.match(new RegExp(`^# ${key} (\\d+)$`, "m"));
      assert.ok(value, `missing TAP ${key}`);
      return [key, Number(value[1])];
    })
  );
const checks = {};
for (const [name, expectedPass, expectedFail] of [
  ["pressure-pinned", 8, 0],
  ["peg-pinned", 17, 0],
  ["coupled-peg-model", 24, 0],
  ["interest-policy-model", 21, 0],
  ["neckwork-calibration", 5, 0],
  ["source-storage", 8, 0],
  ["route-calibration", 8, 0],
  ["prime-replenishment", 4, 0],
  ["rounding", 3, 0],
  ["pressure-model", 7, 1],
  ["peg-model", 15, 2],
]) {
  const file = `/tmp/propeller-rc-${name}-20260923.log`;
  const result = counts(readFileSync(file, "utf8"));
  assert.equal(result.pass, expectedPass);
  assert.equal(result.fail, expectedFail);
  assert.equal(result.skipped, 0);
  checks[name] = {
    ...result,
    ...archive(name, file),
    status: expectedFail ? "research-replay-follow-up" : "passed",
  };
}
const regressionFile = "/tmp/propeller-rc-regression-20260923.log";
const regression = readFileSync(regressionFile, "utf8").match(
  /(\d+) tests passed, (\d+) failed, (\d+) skipped/
);
assert.ok(regression);
assert.deepEqual(regression.slice(1), ["287", "0", "11"]);
checks.solidity = {
  passed: 287,
  failed: 0,
  skipped: 11,
  ...archive("solidity", regressionFile),
};
for (const name of ["keeper", "keeper-build"]) {
  checks[name] = archive(name, `/tmp/propeller-rc-${name}-20260923.log`);
}
const previous = json(
  "propeller-vault/docs/evidence/route-execution-2026-09-23/summary.json"
);
const artifacts = {};
for (const [name, expected] of Object.entries(previous.productionArtifacts)) {
  const artifact = json(`propeller-vault/out/${name}.sol/${name}.json`);
  const bytes = Buffer.from(
    artifact.deployedBytecode.object.replace(/^0x/, ""),
    "hex"
  );
  assert.equal(
    hash(bytes),
    expected.templateSha256,
    `${name}: runtime changed`
  );
  assert.ok(bytes.length <= 24576, `${name}: EIP-170 exceeded`);
  const metadata =
    typeof artifact.metadata === "string"
      ? JSON.parse(artifact.metadata)
      : artifact.metadata;
  for (const [source, entry] of Object.entries(metadata.sources).filter(
    ([source]) => source.startsWith("src/")
  )) {
    assert.equal(
      keccak256(readFileSync(resolve("propeller-vault", source))),
      entry.keccak256,
      `${source}: stale artifact`
    );
  }
  artifacts[name] = {
    runtimeBytes: bytes.length,
    templateSha256: hash(bytes),
    localSourcesMatch: true,
  };
}
const result = {
  date: "2026-09-23",
  scope: "RC1 review checkpoint, not production activation approval",
  logFormatting:
    "Trailing whitespace and empty final lines normalized; raw-input and archived hashes are both recorded.",
  checks,
  artifacts,
  fixtures: {
    historical: "../../../../scripts/propeller/fixtures/market-20260922.json",
    freshRoute: "../route-execution-2026-09-23/market.json",
    pricing: "../prime-validation-2026-09-23/summary.json",
  },
  limitations: [
    "Eleven ordinary Forge skips: eight opt-in campaign methods and three optional setups. Separate campaign/fork evidence retains its own scope.",
    "Keeper runner reports two test files, not two individual assertions; its build completed separately.",
    "Historical pressure and peg suites pass with their checked-in September 22 fixture. Substituting the September 23 route fixture exposes one rejected-quote search failure and two snapshot-specific shock threshold failures. These are recorded, not waived or counted as passes.",
    "Fresh pricing/refill and native-route calibration suites pass with their explicitly selected archived fixtures.",
    "No Solidity changes were made during the documentation handoff; runtime templates and local source hashes match prior native evidence.",
  ],
};
writeFileSync(
  resolve(output, "summary.json"),
  JSON.stringify(result, null, 2) + "\n"
);
console.log(
  JSON.stringify({
    output,
    artifacts: Object.keys(artifacts).length,
    checks: Object.keys(checks).length,
  })
);
