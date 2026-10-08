// Conservative storage-prefix gate, not a proof of upgrade semantics or safety.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { utils } from "ethers";

const root = fileURLToPath(new URL("../../propeller-vault/", import.meta.url));
export const baselinePath = join(root, "docs/evidence/source-upgrades-2026-09-23/subloop-storage.json");

export function normalizeLayout(layout) {
  function type(id, seen = new Set()) {
    const t = layout.types[id];
    assert.ok(t, `unknown storage type ${id}`);
    const result = { label: t.label, encoding: t.encoding, numberOfBytes: t.numberOfBytes };
    if (seen.has(id)) return { ...result, recursiveReference: true };
    const next = new Set([...seen, id]);
    for (const key of ["key", "value", "base"]) if (t[key]) result[key] = type(t[key], next);
    if (t.members) result.members = t.members.map(m => ({ label: m.label, slot: m.slot,
      offset: m.offset, type: type(m.type, next) }));
    return result;
  }
  return layout.storage.map(s => ({ label: s.label, slot: s.slot, offset: s.offset, type: type(s.type) }));
}

export function assertLayoutCompatible(baseline, candidate) {
  assert.equal(candidate.format, 1);
  assert.equal(baseline.format, 1);
  assert.equal(candidate.compiler, baseline.compiler, "compiler changes require separate review");
  assert.ok(baseline.storage.length > 0, "empty baseline");
  assert.ok(candidate.storage.length >= baseline.storage.length, "existing storage removed");
  assert.deepEqual(candidate.storage.slice(0, baseline.storage.length), baseline.storage,
    "existing slots, packed offsets, types, inheritance order and gaps must remain unchanged");
  let end = 0n;
  for (const entry of baseline.storage) {
    const after = BigInt(entry.slot) * 32n + BigInt(entry.offset) + BigInt(entry.type.numberOfBytes);
    if (after > end) end = after;
  }
  for (const entry of candidate.storage.slice(baseline.storage.length)) {
    const start = BigInt(entry.slot) * 32n + BigInt(entry.offset);
    assert.ok(start >= end, "new storage overlaps old or appended storage");
    end = start + BigInt(entry.type.numberOfBytes);
  }
}

function compilerPath() {
  if (process.env.SOLC) return process.env.SOLC;
  const candidates = [
    join(process.env.XDG_DATA_HOME || join(homedir(), ".local/share"), "svm/0.8.22/solc-0.8.22"),
    join(homedir(), ".svm/0.8.22/solc-0.8.22"),
  ];
  const installed = candidates.find(existsSync);
  assert.ok(installed, "set SOLC to the installed pinned Solc 0.8.22 binary");
  return installed;
}

function compileLayout(artifactPath, solc) {
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const metadata = artifact.metadata || JSON.parse(artifact.rawMetadata);
  const targets = Object.entries(metadata.settings.compilationTarget);
  assert.equal(targets.length, 1);
  const [source, contract] = targets[0];
  const version = spawnSync(solc, ["--version"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(version.status, 0, version.error?.message || version.stderr);
  assert.ok(version.stdout.includes(metadata.compiler.version), "artifact/compiler version mismatch");
  const sources = Object.fromEntries(Object.entries(metadata.sources).map(([path, expected]) => {
    const content = readFileSync(resolve(root, path), "utf8");
    assert.equal(utils.keccak256(Buffer.from(content)), expected.keccak256,
      `stale artifact: rebuild before checking ${path}`);
    return [path, { content }];
  }));
  const settings = { ...metadata.settings, outputSelection: { [source]: { [contract]: ["storageLayout"] } } };
  delete settings.compilationTarget;
  // Layout-only compilation avoids changing Forge's shared bytecode/cache outputs.
  const temporary = mkdtempSync(join(tmpdir(), "propeller-storage-"));
  let fd;
  let result;
  try {
    const path = join(temporary, "input.json");
    writeFileSync(path, JSON.stringify({ language: "Solidity", sources, settings }) + "\n");
    // File-backed stdin avoids native Solc waiting on a subprocess socket's EOF.
    fd = openSync(path, "r");
    result = spawnSync(solc, ["--standard-json", "--base-path", root], {
      cwd: root, stdio: [fd, "pipe", "pipe"], encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024, timeout: 60_000,
    });
  } finally {
    if (fd !== undefined) closeSync(fd);
    rmSync(temporary, { recursive: true, force: true });
  }
  assert.equal(result.status, 0, result.error?.message || result.stderr);
  const output = JSON.parse(result.stdout);
  const errors = (output.errors || []).filter(e => e.severity === "error");
  assert.equal(errors.length, 0, errors.map(e => e.formattedMessage).join("\n"));
  return { format: 1, compiler: metadata.compiler.version, source, contract,
    storage: normalizeLayout(output.contracts[source][contract].storageLayout) };
}

function main() {
  const { values } = parseArgs({ options: {
    artifact: { type: "string", default: join(root, "out/SubLoop.sol/SubLoop.json") },
    baseline: { type: "string", default: baselinePath },
    solc: { type: "string" },
    "write-baseline": { type: "boolean", default: false },
  } });
  const candidate = compileLayout(resolve(values.artifact), values.solc || compilerPath());
  const path = resolve(values.baseline);
  if (values["write-baseline"]) {
    assert.ok(!existsSync(path), "refusing to overwrite an existing upgrade baseline");
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, JSON.stringify({
      scope: "2026-09-23 local research baseline, not a deployed implementation. Freeze the actual release layout before launch.",
      ...candidate,
    }, null, 2) + "\n");
    console.log(`Created ${path}; review before treating it as an upgrade baseline.`);
    return;
  }
  const baseline = JSON.parse(readFileSync(path, "utf8"));
  assertLayoutCompatible(baseline, candidate);
  console.log(JSON.stringify({ compatibleStoragePrefix: true, source: candidate.source,
    contract: candidate.contract, preservedEntries: baseline.storage.length,
    appendedEntries: candidate.storage.length - baseline.storage.length,
    limitation: "No semantic, assembly-slot, economic or migration safety proof; gaps are conservatively frozen." }, null, 2));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
