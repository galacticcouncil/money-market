import assert from "node:assert/strict";
import { test } from "node:test";
import {
  parseRoundingPolicies,
  roundingAlert,
} from "../src/rounding-policy.js";
const vault = "0x0000000000000000000000000000000000000001";
const policy = { vault, assetId: 34, minimum: "100", target: "200" };
const parse = (row: unknown) =>
  parseRoundingPolicies(JSON.stringify([row]), [vault]);
test("rounding policy uses exact base units and covers every vault", () => {
  assert.equal(parse(policy).get(vault)?.target, 200n);
  assert.throws(() => parseRoundingPolicies("[]", [vault]), /exactly/);
  assert.throws(
    () => parseRoundingPolicies(JSON.stringify([policy, policy]), [vault]),
    /duplicate/
  );
});
test("rounding policy rejects ambiguous or unsafe thresholds", () => {
  for (const minimum of [
    "0",
    "-1",
    "1.5",
    "1e10",
    100,
    (1n << 256n).toString(),
  ]) {
    assert.throws(() => parse({ ...policy, minimum }));
  }
  assert.throws(() => parse({ ...policy, target: "100" }), /exceed/);
  assert.throws(() => parse({ ...policy, assetId: -1 }), /asset ID/);
});
test("monitor distinguishes low reserve from missing custody", () => {
  assert.equal(roundingAlert(100n, 100n, 100n), undefined);
  assert.match(roundingAlert(99n, 100n, 100n)!, /below/);
  assert.match(roundingAlert(100n, 99n, 100n)!, /unbacked/);
});
