import assert from "node:assert/strict";
import { test } from "node:test";
import { nativeRoundingPolicy, nativeAccount } from "./rounding-native";
const policy = {
  vault: "0x0000000000000000000000000000000000000001",
  assetId: 34,
  minimum: 200n,
  target: 400n,
};
const collateral = "0x0000000000000000000000000000000100000022";
const api = {
  query: {
    assetRegistry: {
      assets: async () => ({
        isNone: false,
        unwrap: () => ({ existentialDeposit: 100n }),
      }),
    },
  },
  call: {
    evmAccountsApi: { accountId: async () => "native-bound-account" },
    dusterApi: { isWhitelisted: async () => ({ isTrue: true }) },
  },
};
test("native policy uses runtime mapping and dust protection", async () => {
  assert.equal(await nativeAccount(api, policy.vault), "native-bound-account");
  assert.deepEqual(await nativeRoundingPolicy(api, policy, collateral), {
    ed: 100n,
    account: "native-bound-account",
    protectedFromDust: true,
  });
});
test("wrong native asset or minimum at ED fails closed", async () => {
  await assert.rejects(
    () =>
      nativeRoundingPolicy(
        api,
        policy,
        "0x000000000000000000000000000000010000002b"
      ),
    /does not match/
  );
  await assert.rejects(
    () => nativeRoundingPolicy(api, { ...policy, minimum: 100n }, collateral),
    /must exceed/
  );
});
test("unprotected custody is distinguishable from a funded reserve", async () => {
  const unprotected = {
    ...api,
    call: {
      ...api.call,
      dusterApi: { isWhitelisted: async () => ({ isTrue: false }) },
    },
  };
  assert.equal(
    (await nativeRoundingPolicy(unprotected, policy, collateral))
      .protectedFromDust,
    false
  );
});
