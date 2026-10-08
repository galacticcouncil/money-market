// Read-only independent PRIME/wYLDS reference, not an executable USDC quote.
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";

const require = createRequire(import.meta.url);
const bs58 = require("bs58");
const endpoint =
  process.env.SOLANA_RPC || "https://api.mainnet-beta.solana.com";
const program = "97V7JsExNC6yFWu5KjK1FLfVkNVvtMpAFL5QkLWKEGxY";
const discriminator = createHash("sha256")
  .update("account:StakePriceConfig")
  .digest()
  .subarray(0, 8);
const response = await fetch(endpoint, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "getProgramAccounts",
    params: [
      program,
      {
        commitment: "finalized",
        encoding: "base64",
        withContext: true,
        filters: [
          { dataSize: 177 },
          { memcmp: { offset: 0, bytes: bs58.encode(discriminator) } },
        ],
      },
    ],
  }),
  signal: AbortSignal.timeout(60000),
});
if (!response.ok)
  throw new Error(`Solana HTTP ${response.status}: ${await response.text()}`);
const raw = await response.json();
if (raw.error) throw new Error(JSON.stringify(raw.error));
const accounts = raw.result.value.map(({ pubkey, account }) => {
  const b = Buffer.from(account.data[0], "base64");
  if (
    b.length !== 177 ||
    !b.subarray(0, 8).equals(discriminator) ||
    account.owner !== program
  )
    throw new Error("Unexpected price account layout/owner");
  const price = b.readBigUInt64LE(136) + (b.readBigInt64LE(144) << 64n);
  const scale = b.readBigUInt64LE(152),
    updated = Number(b.readBigInt64LE(160));
  const maxStaleness = Number(b.readBigInt64LE(168));
  if (price <= 0n || scale === 0n) throw new Error("Uninitialized price");
  return {
    address: pubkey,
    priceRaw: price.toString(),
    scale: scale.toString(),
    wyldsPerPrime: Number(price) / Number(scale),
    updatedAt: new Date(updated * 1000).toISOString(),
    ageSeconds: Date.now() / 1000 - updated,
    maxStalenessSeconds: maxStaleness,
    fresh: Date.now() / 1000 - updated <= maxStaleness,
  };
});
const result = {
  endpoint,
  program,
  slot: raw.result.context.slot,
  retrievedAt: new Date().toISOString(),
  accounts,
  raw,
  caveat:
    "PRIME/wYLDS reference only. Does not verify pauses, executable size, USDC redemption funding, bridging, or a settlement commitment.",
};
const output = process.argv[2] || "/tmp/propeller-prime-reference.json";
writeFileSync(output, JSON.stringify(result, null, 2) + "\n");
console.log(output, { ...result, raw: undefined });
