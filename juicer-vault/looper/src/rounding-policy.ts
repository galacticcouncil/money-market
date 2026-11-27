export type RoundingPolicy = {
  vault: string;
  assetId: number;
  minimum: bigint;
  target: bigint;
};

// Native base units, never floating-point token amounts.
export function parseRoundingPolicies(
  json: string,
  vaults: readonly string[]
): Map<string, RoundingPolicy> {
  const rows: unknown = JSON.parse(json);
  if (!Array.isArray(rows))
    throw new Error("rounding policy must be a JSON array");
  const result = new Map<string, RoundingPolicy>();
  const amount = (value: unknown): bigint => {
    if (typeof value !== "string" || !/^[1-9][0-9]*$/.test(value))
      throw new Error("rounding amounts must be positive integer strings");
    const n = BigInt(value);
    if (n >= 1n << 256n) throw new Error("rounding amount exceeds uint256");
    return n;
  };
  for (const row of rows) {
    if (
      !row ||
      typeof row.vault !== "string" ||
      !/^0x[0-9a-fA-F]{40}$/.test(row.vault) ||
      /^0x0{40}$/.test(row.vault)
    )
      throw new Error("invalid rounding vault");
    const key = row.vault.toLowerCase();
    if (result.has(key)) throw new Error("duplicate rounding vault");
    if (
      !Number.isInteger(row.assetId) ||
      row.assetId < 0 ||
      row.assetId > 0xffffffff
    )
      throw new Error("invalid rounding asset ID");
    const minimum = amount(row.minimum);
    const target = amount(row.target);
    if (target <= minimum)
      throw new Error("rounding target must exceed alert minimum");
    result.set(key, {
      vault: row.vault,
      assetId: row.assetId,
      minimum,
      target,
    });
  }
  if (
    result.size !== vaults.length ||
    vaults.some((v) => !result.has(v.toLowerCase()))
  ) {
    throw new Error(
      "rounding policies must cover exactly the configured vaults"
    );
  }
  return result;
}

export function roundingAlert(
  reserve: bigint,
  raw: bigint,
  minimum: bigint
): string | undefined {
  if (raw < reserve)
    return `rounding reserve unbacked: raw=${raw}, reserved=${reserve}`;
  if (reserve < minimum)
    return `rounding reserve below minimum: reserved=${reserve}, minimum=${minimum}`;
  return undefined;
}
