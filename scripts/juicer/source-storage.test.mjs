import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { assertLayoutCompatible, baselinePath, normalizeLayout } from "./check-source-storage.mjs";

const baseline = JSON.parse(readFileSync(baselinePath, "utf8"));
const fresh = () => structuredClone(baseline);

test("identical layout preserves the baseline", () => assertLayoutCompatible(baseline, fresh()));

test("append-only storage after the preserved gaps is allowed", () => {
  const candidate = fresh();
  const last = candidate.storage.at(-1);
  const start = (BigInt(last.slot) * 32n + BigInt(last.offset) + BigInt(last.type.numberOfBytes) + 31n) / 32n;
  candidate.storage.push({ label: "newPolicy", slot: start.toString(), offset: 0,
    type: { label: "uint256", encoding: "inplace", numberOfBytes: "32" } });
  assertLayoutCompatible(baseline, candidate);
  candidate.storage.at(-1).slot = "0";
  assert.throws(() => assertLayoutCompatible(baseline, candidate), /overlaps/);
});

test("a changed existing slot fails", () => {
  const candidate = fresh();
  candidate.storage.find(s => s.label === "principalEquity").slot = "0";
  assert.throws(() => assertLayoutCompatible(baseline, candidate));
});

test("packed offsets and scalar types cannot drift", () => {
  const candidate = fresh();
  candidate.storage[0].offset += 1;
  assert.throws(() => assertLayoutCompatible(baseline, candidate));
  const typed = fresh();
  typed.storage[0].type.numberOfBytes = "32";
  assert.throws(() => assertLayoutCompatible(baseline, typed));
});

test("mapping value structure remains part of the compatibility boundary", () => {
  const candidate = fresh();
  const roles = candidate.storage.find(s => s.label === "_roles");
  assert.ok(roles.type.value.members.length > 0);
  roles.type.value.members[0].slot = "9";
  assert.throws(() => assertLayoutCompatible(baseline, candidate));
});

test("removal and inheritance reordering fail", () => {
  const candidate = fresh();
  candidate.storage.pop();
  assert.throws(() => assertLayoutCompatible(baseline, candidate), /removed/);
  const reordered = fresh();
  [reordered.storage[0], reordered.storage[1]] = [reordered.storage[1], reordered.storage[0]];
  assert.throws(() => assertLayoutCompatible(baseline, reordered));
});

test("gap consumption and compiler changes require separate review", () => {
  const candidate = fresh();
  candidate.storage.at(-1).type.numberOfBytes = "32";
  assert.throws(() => assertLayoutCompatible(baseline, candidate));
  const compiler = fresh();
  compiler.compiler = "different compiler";
  assert.throws(() => assertLayoutCompatible(baseline, compiler), /compiler/);
});

test("compiler AST identifiers do not cause false incompatibility", () => {
  const layout = id => ({ storage: [{ astId: id, contract: `Fixture${id}`, label: "owner",
    slot: "0", offset: 0, type: `contract${id}` }],
    types: { [`contract${id}`]: { encoding: "inplace", label: "contract Owner", numberOfBytes: "20" } } });
  assert.deepEqual(normalizeLayout(layout(1)), normalizeLayout(layout(99)));
});
