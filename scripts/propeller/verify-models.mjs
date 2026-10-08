// Replay every model/calibration suite with explicit archived inputs. Run from
// any directory; HYDRATION_MATH_ROOT selects the pinned Hydration SDK packages.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadMath } from "./pressure-model.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const output = process.argv[2]
  ? resolve(process.argv[2])
  : mkdtempSync(join(tmpdir(), "propeller-models-"));
mkdirSync(output, { recursive: true });
const evidence = "propeller-vault/docs/evidence";
const fixtures = {
  historical: "scripts/propeller/fixtures/market-20260922.json",
  route: `${evidence}/route-execution-2026-09-23/market.json`,
};
const hash = (body) => createHash("sha256").update(body).digest("hex");
const summary = {
  scope:
    "Archived model replay, not a fresh native fork or production capacity approval",
  node: process.version,
  mathDependencies: loadMath(process.env.HYDRATION_MATH_ROOT).dependencies,
  fixtures: Object.fromEntries(
    Object.entries(fixtures).map(([name, file]) => [
      name,
      { file, sha256: hash(readFileSync(join(root, file))) },
    ])
  ),
  checks: {},
};
const jobs = Object.keys(fixtures).flatMap((fixture) =>
  [
    "pressure-model",
    "peg-model",
    "coupled-peg-model",
    "interest-policy-model",
  ].map((suite) => ({ suite, fixture }))
);
jobs.push(
  ...[
    "route-calibration",
    "prime-replenishment",
    "neckwork-calibration",
    "source-storage",
  ].map((suite) => ({ suite, fixture: "route" }))
);
let failed = false;
for (const { suite, fixture } of jobs) {
  const name = `${suite}-${fixture}`;
  const args = ["--test-reporter=tap", `scripts/propeller/${suite}.test.mjs`];
  const result = spawnSync(process.execPath, args, {
    cwd: root,
    env: {
      ...process.env,
      PROPELLER_MARKET_SNAPSHOT: join(root, fixtures[fixture]),
      PROPELLER_ROUTE_EVIDENCE: join(
        root,
        evidence,
        "route-execution-2026-09-23/native-baseline.json"
      ),
      PRIME_VALIDATION_EVIDENCE: join(
        root,
        evidence,
        "prime-validation-2026-09-23"
      ),
    },
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  const log = `${result.stdout || ""}${result.stderr || ""}${
    result.error ? `${result.error}\n` : ""
  }`;
  const counts = Object.fromEntries(
    ["tests", "pass", "fail", "skipped"].map((key) => [
      key,
      Number(log.match(new RegExp(`^# ${key} (\\d+)$`, "m"))?.[1] ?? NaN),
    ])
  );
  const passed =
    result.status === 0 &&
    counts.tests > 0 &&
    counts.pass === counts.tests &&
    counts.fail === 0 &&
    counts.skipped === 0;
  writeFileSync(join(output, `${name}.log`), log);
  summary.checks[name] = {
    command: ["node", ...args],
    fixture,
    ...counts,
    status: passed ? "passed" : "failed",
    exitCode: result.status,
    file: `${name}.log`,
    sha256: hash(log),
  };
  failed ||= !passed;
  console.log(
    `${name}: ${summary.checks[name].status} (${counts.pass}/${counts.tests}, ${counts.skipped} skipped)`
  );
}
writeFileSync(
  join(output, "summary.json"),
  JSON.stringify(summary, null, 2) + "\n"
);
console.log(output);
process.exitCode = failed ? 1 : 0;
