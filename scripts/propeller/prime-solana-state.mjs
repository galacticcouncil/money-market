// Read-only snapshot. Borsh layouts follow the pinned Hastra/NTT sources.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { refillCapacity } from "./prime-replenishment.mjs";
const deps = createRequire(
  resolve(process.env.SOLANA_DEPS_ROOT || "/home/mrq/git/whm", "package.json")
);
const { PublicKey } = deps("@solana/web3.js");
const { AccountLayout, MintLayout, TOKEN_PROGRAM_ID } =
  deps("@solana/spl-token");
const b = createRequire(deps.resolve("@coral-xyz/anchor"))("@coral-xyz/borsh");
const endpoint =
  process.env.SOLANA_RPC || "https://api.mainnet-beta.solana.com";
const STAKE = "97V7JsExNC6yFWu5KjK1FLfVkNVvtMpAFL5QkLWKEGxY";
const MINT = "9WUyNREiPDMgwMh5Gt81Fd3JpiCKxpjZ5Dpq9Bo1RhMV";
const NTT = "4T5m5NtRVewiCVzP2mnfeUoMYRqncfkrS21X2dhVCNRT";
const PRIME = "3b8X44fLF9ooXaUm3hhSgjpmVs6rZZ3pPoGnGahc3Uu7";
const pubkey = (name) => b.publicKey(name);
const admins = () => [
  b.vec(pubkey(), "freezeAdministrators"),
  b.vec(pubkey(), "rewardsAdministrators"),
];
const layouts = {
  StakeConfig: b.struct([
    pubkey("vault"),
    pubkey("mint"),
    b.i64("unbondingPeriod"),
    ...admins(),
    b.u8("bump"),
    b.bool("paused"),
  ]),
  StakePriceConfig: b.struct([
    pubkey("chainlinkProgram"),
    pubkey("chainlinkVerifierAccount"),
    pubkey("chainlinkAccessController"),
    b.array(b.u8(), 32, "feedId"),
    b.i128("price"),
    b.u64("priceScale"),
    b.i64("priceTimestamp"),
    b.i64("priceMaxStaleness"),
    b.u8("bump"),
  ]),
  StakeVaultTokenAccountConfig: b.struct([
    pubkey("vaultTokenAccount"),
    pubkey("vaultAuthority"),
    b.u8("bump"),
  ]),
  Config: b.struct([
    pubkey("vault"),
    pubkey("mint"),
    ...admins(),
    pubkey("vaultAuthority"),
    pubkey("redeemVault"),
    b.u8("bump"),
    b.bool("paused"),
    pubkey("allowedExternalMintProgram"),
  ]),
  VaultTokenAccountConfig: b.struct([
    pubkey("vaultTokenAccount"),
    b.u8("bump"),
  ]),
  NttConfig: b.struct([
    b.u8("bump"),
    pubkey("owner"),
    b.option(pubkey(), "pendingOwner"),
    pubkey("mint"),
    pubkey("tokenProgram"),
    b.u8("mode"),
    b.u16("chainId"),
    b.u8("nextTransceiverId"),
    b.u8("threshold"),
    b.u128("enabledTransceivers"),
    b.bool("paused"),
    pubkey("custody"),
  ]),
  OutboxRateLimit: b.struct([
    b.u64("limit"),
    b.u64("capacityAtLastTx"),
    b.i64("lastTxTimestamp"),
  ]),
  RedemptionRequest: b.struct([
    pubkey("user"),
    b.u64("amount"),
    pubkey("mint"),
    b.u8("bump"),
  ]),
  PriceFeed: b.struct([
    b.array(b.u8(), 32, "assetId"),
    b.u16("priceIndex"),
    pubkey("scopePrices"),
  ]),
};
const disc = (name) =>
  createHash("sha256").update(`account:${name}`).digest().subarray(0, 8);
const normalize = (value) => {
  if (value === null || value === undefined) return value;
  if (typeof value === "bigint") return value.toString();
  if (value.toBase58) return value.toBase58();
  if (value.constructor?.name === "BN") return value.toString();
  if (Array.isArray(value)) return value.map(normalize);
  if (typeof value === "object")
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, normalize(v)])
    );
  return value;
};
const data = (account) => Buffer.from(account.data[0], "base64");
function decode(type, account, owner) {
  assert.ok(account, `missing ${type}`);
  assert.equal(account.owner, owner);
  const bytes = data(account),
    name = type === "NttConfig" ? "Config" : type;
  assert.ok(
    bytes.subarray(0, 8).equals(disc(name)),
    `${type}: wrong discriminator`
  );
  return normalize(layouts[type].decode(bytes.subarray(8)));
}
const pda = (program, ...seeds) =>
  PublicKey.findProgramAddressSync(
    seeds.map((s) => (typeof s === "string" ? Buffer.from(s) : s)),
    new PublicKey(program)
  )[0].toBase58();
const result = {
  retrievedAt: new Date().toISOString(),
  endpoint,
  programs: { stake: STAKE, mint: MINT, ntt: NTT },
  raw: {},
  errors: {},
};
const save = () =>
  writeFileSync(
    process.argv[2] || "/tmp/propeller-prime-solana-state.json",
    JSON.stringify(result, null, 2) + "\n"
  );
let requestId = 0;
async function rpc(key, method, params) {
  for (let attempt = 0; ; attempt++) {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++requestId, method, params }),
      signal: AbortSignal.timeout(60000),
    });
    if (response.status === 429 && attempt < 4) {
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
      continue;
    }
    assert.ok(response.ok, `${method}: HTTP ${response.status}`);
    const raw = await response.json();
    if (raw.error) throw new Error(`${method}: ${JSON.stringify(raw.error)}`);
    result.raw[key] = raw.result;
    save();
    return raw.result;
  }
}
try {
  const stakeConfig = pda(STAKE, "stake_config"),
    mintConfig = pda(MINT, "config");
  const addresses = {
    stakeConfig,
    mintConfig,
    price: pda(
      STAKE,
      "stake_price_config",
      new PublicKey(stakeConfig).toBuffer()
    ),
    stakeVaultConfig: pda(
      STAKE,
      "stake_vault_token_account_config",
      new PublicKey(stakeConfig).toBuffer()
    ),
    mintVaultConfig: pda(
      MINT,
      "vault_token_account_config",
      new PublicKey(mintConfig).toBuffer()
    ),
    nttConfig: pda(NTT, "config"),
    nttOutbox: pda(NTT, "outbox_rate_limit"),
  };
  const types = [
    "StakeConfig",
    "Config",
    "StakePriceConfig",
    "StakeVaultTokenAccountConfig",
    "VaultTokenAccountConfig",
    "NttConfig",
    "OutboxRateLimit",
  ];
  const owners = [STAKE, MINT, STAKE, STAKE, MINT, NTT, NTT];
  const initial = await rpc("configuration", "getMultipleAccounts", [
    Object.values(addresses),
    { commitment: "finalized", encoding: "base64" },
  ]);
  const config = Object.fromEntries(
    Object.keys(addresses).map((k, i) => [
      k,
      decode(types[i], initial.value[i], owners[i]),
    ])
  );
  assert.equal(config.stakeConfig.mint, PRIME);
  assert.equal(config.nttConfig.mint, PRIME);
  assert.equal(config.stakeConfig.vault, config.mintConfig.mint);
  const tokenAddresses = {
    primeMint: PRIME,
    wyldsMint: config.mintConfig.mint,
    usdcMint: config.mintConfig.vault,
    stakeWylds: config.stakeVaultConfig.vaultTokenAccount,
    depositUsdc: config.mintVaultConfig.vaultTokenAccount,
    redeemUsdc: config.mintConfig.redeemVault,
    nttCustody: config.nttConfig.custody,
  };
  const all = { ...addresses, ...tokenAddresses };
  const batch = await rpc("coherentAccounts", "getMultipleAccounts", [
    Object.values(all),
    {
      commitment: "finalized",
      encoding: "base64",
      minContextSlot: initial.context.slot,
    },
  ]);
  result.slot = batch.context.slot;
  result.addresses = all;
  const names = Object.keys(addresses);
  result.configuration = Object.fromEntries(
    names.map((k, i) => [k, decode(types[i], batch.value[i], owners[i])])
  );
  // Resolve pointers and read balances in one final batch; fail if pointers raced.
  for (const [key, field] of [
    ["stakeConfig", "mint"],
    ["stakeConfig", "vault"],
    ["mintConfig", "mint"],
    ["mintConfig", "vault"],
    ["mintConfig", "redeemVault"],
    ["stakeVaultConfig", "vaultTokenAccount"],
    ["mintVaultConfig", "vaultTokenAccount"],
    ["nttConfig", "custody"],
  ])
    assert.equal(result.configuration[key][field], config[key][field]);
  result.tokens = {};
  for (const [i, [name, address]] of Object.entries(tokenAddresses).entries()) {
    const account = batch.value[names.length + i];
    assert.ok(account, `missing ${name}`);
    assert.equal(account.owner, TOKEN_PROGRAM_ID.toBase58());
    const bytes = data(account),
      mint = name.endsWith("Mint");
    assert.equal(bytes.length, mint ? MintLayout.span : AccountLayout.span);
    result.tokens[name] = {
      address,
      ...normalize((mint ? MintLayout : AccountLayout).decode(bytes)),
    };
  }
  for (const name of ["primeMint", "wyldsMint", "usdcMint"])
    assert.equal(result.tokens[name].decimals, 6);
  for (const [name, mint] of [
    ["stakeWylds", "wyldsMint"],
    ["depositUsdc", "usdcMint"],
    ["redeemUsdc", "usdcMint"],
    ["nttCustody", "primeMint"],
  ])
    assert.equal(result.tokens[name].mint, result.tokens[mint].address);
  const clock = await rpc("blockTime", "getBlockTime", [result.slot]);
  result.blockTime = clock;
  const p = result.configuration.price,
    price = BigInt(p.price),
    scale = BigInt(p.priceScale);
  assert.ok(price > 0n && scale > 0n && Number(p.priceTimestamp) > 0);
  result.reference = {
    wyldsPerPrime: Number(price) / Number(scale),
    updatedAt: new Date(Number(p.priceTimestamp) * 1000).toISOString(),
    ageSeconds: clock - Number(p.priceTimestamp),
    maxStalenessSeconds: Number(p.priceMaxStaleness),
    fresh:
      clock >= Number(p.priceTimestamp) &&
      clock - Number(p.priceTimestamp) <= Number(p.priceMaxStaleness),
    feedId: "0x" + Buffer.from(p.feedId).toString("hex"),
  };
  const inventory = BigInt(result.tokens.stakeWylds.amount),
    supply = BigInt(result.tokens.primeMint.supply);
  result.liquidity = {
    stakeWylds: Number(inventory) / 1e6,
    primeSupply: Number(supply) / 1e6,
    wyldsPerPrimeFromInventory: Number(inventory) / Number(supply),
    redeemablePrimeAtReference: Number((inventory * scale) / price) / 1e6,
    primeClaimWylds: Number((supply * price) / scale) / 1e6,
    usdcDepositVault: Number(result.tokens.depositUsdc.amount) / 1e6,
    usdcRedemptionVault: Number(result.tokens.redeemUsdc.amount) / 1e6,
    nttCustodyPrime: Number(result.tokens.nttCustody.amount) / 1e6,
  };
  const rate = result.configuration.nttOutbox;
  const cap = refillCapacity(
    BigInt(rate.limit),
    BigInt(rate.capacityAtLastTx),
    BigInt(rate.lastTxTimestamp),
    BigInt(clock)
  );
  result.bridge = {
    paused: result.configuration.nttConfig.paused,
    outboundLimitPrime: Number(rate.limit) / 1e6,
    outboundCapacityPrime: Number(cap) / 1e6,
    durationSeconds: 86400,
    limitation:
      "Immediate-release capacity, not a hard daily transfer maximum: excess outbound transfers can be queued for 24h. No maker capital or execution SLA implied.",
  };
  try {
    const bs58 = createRequire(new URL("../../package.json", import.meta.url))(
      "bs58"
    );
    const requests = await rpc("pendingRequests", "getProgramAccounts", [
      MINT,
      {
        commitment: "finalized",
        withContext: true,
        encoding: "base64",
        filters: [
          { dataSize: 81 },
          {
            memcmp: {
              offset: 0,
              bytes: bs58.encode(disc("RedemptionRequest")),
            },
          },
        ],
      },
    ]);
    const decoded = requests.value.map((x) => ({
      address: x.pubkey,
      ...decode("RedemptionRequest", x.account, MINT),
    }));
    result.redemptionRequests = {
      slot: requests.context.slot,
      count: decoded.length,
      requestedWylds:
        Number(decoded.reduce((sum, x) => sum + BigInt(x.amount), 0n)) / 1e6,
      requests: decoded,
      limitation:
        "Outstanding requests at a later snapshot, not settlement-time evidence; user balances/delegations can change.",
    };
  } catch (e) {
    result.errors.pendingRequests = String(e);
  }
  result.limitations = [
    "Read-only configuration and liquidity checks; no user mint, redeem or bridge transaction submitted.",
    "Token balances do not independently prove off-chain backing, USD parity or availability to Propeller.",
    "Source-layout compatibility is checked; deployed Solana binaries were not reproducibly matched to repository builds.",
  ];
  try {
    const feedAddress = "F91oB5TobNzjjcEYj3pVRiz33EzH2H9ibHyVcwa1B8Sc",
      emitter = "8j68bb2BLUSgEW6rdF3LnkxZFGieokLfJMBVd8bjATiz";
    const feed = await rpc("relayFeed", "getAccountInfo", [
      feedAddress,
      { commitment: "finalized", encoding: "base64" },
    ]);
    const binding = decode("PriceFeed", feed.value, emitter);
    const scope = await rpc("scope", "getAccountInfo", [
      binding.scopePrices,
      { commitment: "finalized", encoding: "base64" },
    ]);
    const fields = b.struct([
      b.u64("value"),
      b.u64("exponent"),
      b.u64("updatedSlot"),
      b.i64("timestamp"),
    ]);
    const entry = normalize(
      fields.decode(data(scope.value), 40 + binding.priceIndex * 56)
    );
    assert.ok(Number(entry.exponent) <= 38);
    result.relaySource = {
      address: feedAddress,
      binding,
      scopeOwner: scope.value.owner,
      entry,
      price: Number(entry.value) / 10 ** Number(entry.exponent),
      ageSeconds: clock - Number(entry.timestamp),
      scopeSlot: scope.context.slot,
      limitation:
        "Legacy emitter's configured Scope entry, not the proven source of the replacement Hydration oracle. Neither USD redemption nor receiver liveness is established by this binding.",
    };
  } catch (e) {
    result.errors.relaySource = String(e);
  }
  save();
  console.log(
    JSON.stringify(
      {
        slot: result.slot,
        reference: result.reference,
        liquidity: result.liquidity,
        bridge: result.bridge,
        pauses: {
          stake: result.configuration.stakeConfig.paused,
          mint: result.configuration.mintConfig.paused,
        },
        requests: result.redemptionRequests?.count,
        errors: result.errors,
      },
      null,
      2
    )
  );
} catch (e) {
  result.errors.fatal = String(e);
  save();
  throw e;
}
