import { RoundingPolicy } from "../../propeller-vault/looper/src/rounding-policy";

export async function nativeAccount(
  api: any,
  address: string
): Promise<string> {
  return (await api.call.evmAccountsApi.accountId(address)).toString();
}

export async function nativeRoundingPolicy(
  api: any,
  policy: RoundingPolicy,
  collateral: string
) {
  const expected = `0x${((1n << 32n) + BigInt(policy.assetId))
    .toString(16)
    .padStart(40, "0")}`;
  if (collateral.toLowerCase() !== expected)
    throw new Error("rounding asset ID does not match vault native collateral");
  const entry = await api.query.assetRegistry.assets(policy.assetId);
  if (entry.isNone) throw new Error("rounding collateral not registered");
  const ed = BigInt(entry.unwrap().existentialDeposit.toString());
  if (policy.minimum <= ed)
    throw new Error(`rounding minimum must exceed existential deposit ${ed}`);
  const account = await nativeAccount(api, policy.vault);
  const protectedFromDust = (await api.call.dusterApi.isWhitelisted(account))
    .isTrue;
  return { ed, account, protectedFromDust };
}
