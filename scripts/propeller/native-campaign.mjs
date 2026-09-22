// Local-only multi-user, multi-vault rehearsal. Public dev keys, no live writes.
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import assert from "node:assert/strict";
const require = createRequire(new URL("../../package.json", import.meta.url));
const { ApiPromise, WsProvider } = require("@polkadot/api");
const {
  hexToU8a,
  u8aToHex,
  u8aConcat,
  compactToU8a,
} = require("@polkadot/util");
const { blake2AsHex } = require("@polkadot/util-crypto");
const {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  encodeFunctionData,
  keccak256,
} = require("viem");
const { mnemonicToAccount } = require("viem/accounts");
const PORT = Number(process.env.PROPELLER_LOCAL_PORT || 8141);
assert.ok(Number.isInteger(PORT) && PORT > 0 && PORT <= 65535);
const RPC = `http://127.0.0.1:${PORT}`;
const FILE = process.argv[2] || "/tmp/propeller-campaign-result-20260918.json";
const r = JSON.parse(readFileSync(FILE));
assert.equal(r.rpc, RPC, "result belongs to another local fork");
const art = (n) =>
  JSON.parse(
    readFileSync(
      new URL(`../../propeller-vault/out/${n}.sol/${n}.json`, import.meta.url)
    )
  );
const accounts = [0, 1, 2].map((addressIndex) =>
  mnemonicToAccount(
    "test test test test test test test test test test test junk",
    { addressIndex }
  )
);
const [admin, alice, bob] = accounts;
const chain = {
  id: r.fork.chainId,
  name: "Local only",
  nativeCurrency: { name: "WETH", symbol: "WETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};
const pub = createPublicClient({
  chain,
  transport: http(RPC, { timeout: 180000 }),
  pollingInterval: 1000,
  cacheTime: 0,
});
const ws = new WsProvider(`ws://127.0.0.1:${PORT}`, 2500, {}, 180000);
const api = await ApiPromise.create({ provider: ws, noInitWarn: true });
const { pool, hollar, prime, hollarDebt } = r.market;
const {
  source,
  vault: ethVault,
  synth,
  fees,
  harvester,
  discount,
  vaultImpl,
} = r.addresses;
const token = (id) =>
  `0x${((1n << 32n) + BigInt(id)).toString(16).padStart(40, "0")}`;
const erc20 = parseAbi([
  "function approve(address,uint256) returns(bool)",
  "function transfer(address,uint256) returns(bool)",
  "function balanceOf(address) view returns(uint256)",
]);
const poolAbi = JSON.parse(
  readFileSync(
    new URL("../../deployments/hydration/Pool-Implementation.json", import.meta.url)
  )
).abi;
const save = () =>
  writeFileSync(
    FILE,
    JSON.stringify(r, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2) +
      "\n"
  );
const read = (address, abi, functionName, args = []) =>
  pub.readContract({ address, abi, functionName, args });
const vread = (v, fn, args = []) =>
  read(v, art("CollateralVault").abi, fn, args);
const sread = (fn, args = []) => read(source, art("SubLoop").abi, fn, args);
async function write(
  label,
  address,
  abi,
  functionName,
  args = [],
  account = admin
) {
  label = `campaign.${label}`;
  if (r.calls.some((c) => c.label === label)) return;
  const wallet = createWalletClient({
    account,
    chain,
    transport: http(RPC, { timeout: 180000 }),
  });
  const options = {
    account,
    address,
    abi,
    functionName,
    args,
    gas: 12000000n,
    gasPrice: (await pub.getGasPrice()) * 2n,
    type: "legacy",
  };
  await pub.simulateContract(options);
  let hash;
  for (let attempt = 0; ; attempt++) {
    try {
      hash = await wallet.writeContract({
        ...options,
        gasPrice: options.gasPrice + BigInt(attempt),
      });
      break;
    } catch (e) {
      if (attempt >= 3 || !String(e).includes("Expected input with 32 bytes"))
        throw e;
    }
  }
  const receipt = await pub.waitForTransactionReceipt({
    hash,
    timeout: 240000,
  });
  if (receipt.status !== "success") {
    r.failures ??= [];
    r.failures.push({label, hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed});
    save();
  }
  assert.equal(receipt.status, "success", label);
  r.calls.push({
    label,
    address,
    transactionHash: hash,
    gasUsed: receipt.gasUsed,
    args,
  });
  save();
  console.log(label, "PASS", receipt.gasUsed.toString());
}
async function deploy(name, args, label) {
  const prev = r.deployments.find((x) => x.label === label);
  if (prev) return prev.address;
  const a = art(name),
    wallet = createWalletClient({
      account: admin,
      chain,
      transport: http(RPC, { timeout: 180000 }),
    });
  const options = {
    abi: a.abi,
    bytecode: a.bytecode.object,
    args,
    gas: 12000000n,
    gasPrice: (await pub.getGasPrice()) * 2n,
    type: "legacy",
  };
  let hash;
  for (let attempt = 0; ; attempt++) {
    try {
      hash = await wallet.deployContract({ ...options, gasPrice: options.gasPrice + BigInt(attempt) });
      break;
    } catch (e) {
      if (attempt >= 3 || !String(e).includes("Expected input with 32 bytes")) throw e;
    }
  }
  const receipt = await pub.waitForTransactionReceipt({
    hash,
    timeout: 240000,
  });
  assert.equal(receipt.status, "success");
  const code = await pub.getBytecode({ address: receipt.contractAddress });
  r.deployments.push({
    label,
    address: receipt.contractAddress,
    transactionHash: hash,
    gasUsed: receipt.gasUsed,
    runtimeBytes: (code.length - 2) / 2,
    codeHash: keccak256(code),
  });
  save();
  return receipt.contractAddress;
}
async function root(call, label) {
  if (r.calls.some((c) => c.label === label)) return;
  const hex = call.method.toHex(),
    hash = blake2AsHex(hex),
    body = hexToU8a(hex),
    len = body.length;
  await ws.send("dev_setStorage", [
    [
      [
        api.query.preimage.preimageFor.key([hash, len]),
        u8aToHex(u8aConcat(compactToU8a(len), body)),
      ],
    ],
  ]);
  await ws.send("dev_setStorage", [
    {
      Preimage: {
        RequestStatusFor: [
          [
            [hash],
            { Requested: { maybeTicket: null, count: 1, maybeLen: len } },
          ],
        ],
      },
    },
  ]);
  const target = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
  await ws.send("dev_setStorage", [
    {
      Scheduler: {
        Agenda: [
          [
            [target],
            [
              {
                maybeId: null,
                priority: 0,
                call: { Lookup: { hash_: hash, len } },
                maybePeriodic: null,
                origin: { system: "Root" },
              },
            ],
          ],
        ],
      },
    },
  ]);
  await ws.send("dev_newBlock", [{ count: 1 }]);
  const events = (await api.query.system.events()).map(({ event }) => ({
    section: event.section,
    method: event.method,
    data: event.data.toJSON(),
  }));
  const dispatched = events.find(
    (e) => e.section === "scheduler" && e.method === "Dispatched"
  );
  assert.ok(dispatched, `${label}: scheduler event missing`);
  assert.deepEqual(
    dispatched.data[2],
    { ok: null },
    `${label}: governance call failed`
  );
  r.calls.push({ label, simulatedGovernance: true, events });
  save();
}
async function advance(seconds) {
  // This Chopsticks build exposes milliseconds in the RPC block timestamp.
  const before = BigInt((await api.query.timestamp.now()).toString()) / 1000n;
  const next = before + seconds;
  await ws.send("dev_setStorage", [
    [
      [
        api.query.timestamp.now.key(),
        u8aToHex(
          api.registry.createType("u64", (next * 1000n).toString()).toU8a()
        ),
      ],
    ],
  ]);
  await ws.send("dev_newBlock", [
    {
      count: 1,
      relayChainStateOverrides: [
        [
          "0x1cb6f36e027abb2091cfb5110ab5087f06155b3cd9a8c9e5e9a23fd5dc13a5ed",
          u8aToHex(
            api.registry.createType("u64", (next / 6n + 1n).toString()).toU8a()
          ),
        ],
      ],
    },
  ]);
  const after = BigInt((await api.query.timestamp.now()).toString()) / 1000n;
  assert.ok(
    after >= next && after <= next + 60n,
    "incorrect native time units"
  );
  r.nativeTimeAdvance = { before, after, requestedSeconds: seconds };
  save();
}
try {
  await ws.send("dev_setBlockBuildMode", ["Instant"]);
  if (!r.campaignAccountsFunded) {
    for (const account of accounts) {
      const who = (
        await api.call.evmAccountsApi.accountId(account.address)
      ).toString();
      const entries = [];
      for (const [id, free] of [
        [20, 100n * 10n ** 18n],
        [34, 100n * 10n ** 18n],
        [1000765, 10n ** 18n],
        [43, 1000n * 10n ** 6n],
      ]) {
        entries.push([
          api.query.tokens.accounts.key(who, id),
          u8aToHex(
            api.registry
              .createType("OrmlTokensAccountData", {
                free: free.toString(),
                reserved: 0,
                frozen: 0,
              })
              .toU8a()
          ),
        ]);
      }
      await ws.send("dev_setStorage", [entries]);
    }
    r.campaignAccountsFunded = true;
    r.overrides.push(
      "Fund three public development accounts with local gas/collateral/PRIME fixtures"
    );
    save();
  }
  const adapter = await deploy("NativeRouteSwapper", [], "NativeRouteSwapper");
  const btcReserve = await read(pool, poolAbi, "getReserveData", [
    token(1000765),
  ]);
  const btc = await deploy(
    "ERC1967Proxy",
    [
      vaultImpl,
      encodeFunctionData({
        abi: art("CollateralVault").abi,
        functionName: "initialize",
        args: [
          "Propeller tBTC",
          "ptBTC",
          token(1000765),
          pool,
          source,
          adapter,
          hollar,
          synth,
          btcReserve.aTokenAddress,
          hollarDebt,
          1000n * 10n ** 18n,
          admin.address,
        ],
      }),
    ],
    "CollateralVaultTBTC.proxy"
  );
  r.addresses.tbtcVault = btc;
  const ethBuffer = await vread(ethVault, "operatingBuffer");
  const btcBuffer = await deploy("PropellerOperatingBuffer", [btc], "PropellerOperatingBuffer.tBTC");
  await write("btcBufferBinding", btc, art("CollateralVault").abi, "setOperatingBuffer", [btcBuffer]);
  await write("btcBufferPolicy", btcBuffer, art("PropellerOperatingBuffer").abi, "configure",
    [7 * 86400, 10, 50000000000000000000000000n]);
  r.addresses.tbtcBuffer = btcBuffer;
  r.addresses.testRouteAdapter = adapter;
  save();
  const roots = [];
  for (const address of [source, ethVault, btc, ethBuffer, btcBuffer, fees, harvester, adapter]) {
    const who = await api.call.evmAccountsApi.accountId(address);
    if (!(await api.call.dusterApi.isWhitelisted(who)).isTrue)
      roots.push(api.tx.duster.whitelistAccount(who));
  }
  const ethRoute = [
    { pool: { Stableswap: 143 }, assetIn: 43, assetOut: 222 },
    { pool: { Omnipool: null }, assetIn: 222, assetOut: 420 },
    { pool: { Aave: null }, assetIn: 420, assetOut: 4200 },
    { pool: { Stableswap: 4200 }, assetIn: 4200, assetOut: 1007 },
    { pool: { Aave: null }, assetIn: 1007, assetOut: 34 },
  ];
  const btcRoute = [
    { pool: { Stableswap: 143 }, assetIn: 43, assetOut: 222 },
    { pool: { Omnipool: null }, assetIn: 222, assetOut: 1000765 },
  ];
  roots.push(
    api.tx.router.forceInsertRoute({ assetIn: 43, assetOut: 34 }, ethRoute)
  );
  roots.push(
    api.tx.router.forceInsertRoute({ assetIn: 43, assetOut: 1000765 }, btcRoute)
  );
  roots.push(api.tx.router.forceInsertRoute({ assetIn: 34, assetOut: 222 },
    ethRoute.slice(1).reverse().map(hop => ({pool: hop.pool, assetIn: hop.assetOut, assetOut: hop.assetIn}))));
  roots.push(api.tx.router.forceInsertRoute({ assetIn: 1000765, assetOut: 222 },
    [{pool: {Omnipool: null}, assetIn: 1000765, assetOut: 222}]));
  await root(api.tx.utility.batchAll(roots), "campaign.rootCustodyAndRoutes");
  // Explicit external bootstrap capital, borrowed by the public test donor.
  // This is not strategy yield or a production funding commitment.
  await write("bootstrapApprove", token(34), erc20, "approve", [pool, 20n * 10n ** 18n]);
  await write("bootstrapSupply", pool, poolAbi, "supply", [token(34), 20n * 10n ** 18n, admin.address, 0]);
  await write("bootstrapBorrow", pool, poolAbi, "borrow", [hollar, 20000n * 10n ** 18n, 2n, 0, admin.address]);
  for (const [name, buffer] of [["ETH", ethBuffer], ["tBTC", btcBuffer]]) {
    await write(`${name}.bootstrapApprove`, hollar, erc20, "approve", [buffer, 1000n * 10n ** 18n]);
    await write(`${name}.bootstrapFund`, buffer, art("PropellerOperatingBuffer").abi, "fundBootstrap", [1000n * 10n ** 18n]);
  }
  r.operatingBootstrap = {hollarPerVault: "1000000000000000000000", source: "external fork-only donor debt"};
  await write("btcMinter", synth, art("SyntheticToken").abi, "grantRole", [
    keccak256(Buffer.from("MINTER_ROLE")),
    btc,
  ]);
  await write("btcSource", source, art("SubLoop").abi, "registerVault", [btc]);
  await write("btcHarvester", harvester, art("Harvester").abi, "addVault", [
    btc,
  ]);
  await write("btcFees", btc, art("CollateralVault").abi, "setFeeController", [
    fees,
  ]);
  await write(
    "btcFeeRegistration",
    fees,
    art("PropellerFeeController").abi,
    "registerVault",
    [btc, harvester]
  );
  await write(
    "btcDiscountBinding",
    btc,
    art("CollateralVault").abi,
    "setDiscountController",
    [discount]
  );
  await write(
    "btcDiscount",
    discount,
    art("PropellerDiscount").abi,
    "registerVault",
    [btc]
  );
  await write("tranches", source, art("SubLoop").abi, "setTranches", [
    1000n * 10n ** 18n,
    100n * 10n ** 6n,
  ]);
  r.roundingPolicies = [];
  for (const [v, id] of [
    [ethVault, 34],
    [btc, 1000765],
  ]) {
    const asset = token(id),
      ed = BigInt(
        (await api.query.assetRegistry.assets(id))
          .unwrap()
          .existentialDeposit.toString()
      );
    const target = ed * 4n + 1000000000n,
      minimum = ed * 2n;
    r.roundingPolicies.push({
      vault: v,
      assetId: id,
      minimum: minimum.toString(),
      target: target.toString(),
    });
    await write(`${id}.adapter`, v, art("CollateralVault").abi, "setSwapper", [
      adapter,
    ]);
    await write(
      `${id}.slippage`,
      v,
      art("CollateralVault").abi,
      "setCompoundSlippageBps",
      [100]
    );
    await write(`${id}.reserveApprove`, asset, erc20, "approve", [v, target]);
    await write(
      `${id}.reserveFund`,
      v,
      art("CollateralVault").abi,
      "fundRoundingReserve",
      [target]
    );
    assert.ok((await vread(v, "roundingReserve")) >= minimum);
    const seed = id === 34 ? 10n ** 16n : 10n ** 14n;
    await write(`${id}.seedApprove`, asset, erc20, "approve", [v, seed]);
    if (v === ethVault && !r.checks.entryOracleFloorRejected) {
      // At this pinned snapshot, even a small entry misses the 1% floor.
      // Preserve that launch finding before using an explicit fork-only 1.2% fixture.
      await assert.rejects(() => pub.simulateContract({
        account: admin, address: v, abi: art("CollateralVault").abi,
        functionName: "deposit", args: [seed, admin.address], gas: 12000000n,
      }), /0xf4c0eb20|DispatchFailed/);
      assert.equal(await vread(v, "totalSupply"), 0n);
      r.checks.entryOracleFloorRejected = true;
      r.entryFloorFinding = "Pinned HOLLAR/PRIME quote: 20.5 HOLLAR -> 19.312911 PRIME; Aave PRIME=$1.0505 implies 19.319371 PRIME at 1% floor. Actual route rejects. No production widening approved.";
      save();
    }
    if (v === ethVault) {
      await write("explicitForkOnlyEntryFloor", source, art("SubLoop").abi, "configureDca", [222,43,1043,143,12000]);
      r.testOnlyPolicy.slippagePpm = 12000;
      r.testOnlyPolicy.productionApproval = false;
      save();
    }
    // Initial source swap costs can block the next bootstrap; pre-existing
    // shortfalls are recovered explicitly below, never charged to new holders.
    if (v === btc && (await sread("negativeCarryBps")) > 0n) {
      await write("donorApprove", token(34), erc20, "approve", [
        pool,
        20n * 10n ** 18n,
      ]);
      await write("donorSupply", pool, poolAbi, "supply", [
        token(34),
        20n * 10n ** 18n,
        admin.address,
        0,
      ]);
      await write("donorBorrow", pool, poolAbi, "borrow", [
        hollar,
        10000n * 10n ** 18n,
        2n,
        0,
        admin.address,
      ]);
      await write("seedRecovery", hollar, erc20, "transfer", [
        source,
        10n * 10n ** 18n,
      ]);
    }
    await write(`${id}.seed`, v, art("CollateralVault").abi, "deposit", [
      seed,
      admin.address,
    ]);
  }
  await write("donorApprove", token(34), erc20, "approve", [
    pool,
    20n * 10n ** 18n,
  ]);
  await write("donorSupply", pool, poolAbi, "supply", [
    token(34),
    20n * 10n ** 18n,
    admin.address,
    0,
  ]);
  await write("donorBorrow", pool, poolAbi, "borrow", [
    hollar,
    10000n * 10n ** 18n,
    2n,
    0,
    admin.address,
  ]);
  // Explicitly funded entry friction / interest, recorded independently.
  await write("entrySourceFunding", hollar, erc20, "transfer", [
    source,
    50n * 10n ** 18n,
  ]);
  const positions = [
    { v: ethVault, id: 34, who: alice, amount: 10n ** 17n + 7n },
    { v: ethVault, id: 34, who: bob, amount: 10n ** 17n + 11n },
    { v: btc, id: 1000765, who: alice, amount: 3n * 10n ** 15n + 13n },
    { v: btc, id: 1000765, who: bob, amount: 3n * 10n ** 15n + 17n },
  ];
  for (const [i, p] of positions.entries()) {
    await write(
      `user${i}.approve`,
      token(p.id),
      erc20,
      "approve",
      [p.v, p.amount],
      p.who
    );
    await write(
      `user${i}.deposit`,
      p.v,
      art("CollateralVault").abi,
      "deposit",
      [p.amount, p.who.address],
      p.who
    );
  }
  for (let i = 0; i < 3; i++)
    await write(`ramp${i}`, source, art("SubLoop").abi, "pokeBorrow");
  if (!r.campaignInterestAdvanced) {
    await advance(86400n);
    r.campaignInterestAdvanced = true;
    save();
  }
  // Harvest input is an explicit donated PRIME fixture, NOT fabricated APY.
  await write("yieldApprove", prime, erc20, "approve", [
    pool,
    100n * 10n ** 6n,
  ]);
  await write("yieldFixture", pool, poolAbi, "supply", [
    prime,
    100n * 10n ** 6n,
    source,
    0,
  ]);
  if (!r.campaignPreHarvest) {
    r.campaignPreHarvest = {
      eth: await vread(ethVault, "totalAssets"),
      btc: await vread(btc, "totalAssets"),
      buffers: [],
    };
    for (const v of [ethVault, btc]) {
      const buffer = await vread(v, "operatingBuffer");
      const interest = await read(buffer, art("PropellerOperatingBuffer").abi, "interestOf", [0n]);
      assert.ok(interest > 0n, "native interest must accrue before harvest");
      r.campaignPreHarvest.buffers.push({vault: v, buffer, interest});
    }
    save();
  }
  await write("harvest", harvester, art("Harvester").abi, "harvest", [[]]);
  if (!r.checks.nativeAccruedInterestServicedByHarvest) {
    for (const {buffer} of r.campaignPreHarvest.buffers) {
      assert.equal(await read(buffer, art("PropellerOperatingBuffer").abi, "interestOf", [0n]), 0n);
    }
    r.checks.nativeAccruedInterestServicedByHarvest = true;
    save();
  }
  assert.ok(
    (await vread(ethVault, "totalAssets")) > BigInt(r.campaignPreHarvest.eth)
  );
  assert.ok(
    (await vread(btc, "totalAssets")) > BigInt(r.campaignPreHarvest.btc)
  );
  for (const id of [34, 1000765]) {
    const amount = await read(
      fees,
      art("PropellerFeeController").abi,
      "claimableProtocolFees",
      [token(id)]
    );
    if (!r.calls.some((c) => c.label === `campaign.feeClaim${id}`))
      assert.ok(amount > 0n);
    await write(
      `feeClaim${id}`,
      fees,
      art("PropellerFeeController").abi,
      "claimProtocolFees",
      [token(id)]
    );
    assert.equal(
      await read(
        fees,
        art("PropellerFeeController").abi,
        "claimableProtocolFees",
        [token(id)]
      ),
      0n
    );
  }
  r.checks.nativeMultiUserMultiVaultRealRouteHarvest = true;
  for (const [i, p] of positions.entries()) {
    const shares = await vread(p.v, "balanceOf", [p.who.address]);
    await write(
      `user${i}.request`,
      p.v,
      art("CollateralVault").abi,
      "requestRedeem",
      [shares, p.who.address],
      p.who
    );
  }
  for (const v of [ethVault, btc]) {
    await write(
      `${v}.earlyStart`,
      v,
      art("CollateralVault").abi,
      "startUnwinds",
      [16n]
    );
    assert.equal(await vread(v, "queueUnwind"), 0n);
  }
  if (!r.campaignTimeAdvanced) {
    await advance(7n * 86400n);
    r.campaignTimeAdvanced = true;
    save();
  }
  await write("freeze", source, art("SubLoop").abi, "pauseEmergency");
  for (const v of [ethVault, btc]) {
    assert.equal(await vread(v, "paused"), true);
    await assert.rejects(() =>
      pub.simulateContract({
        account: alice,
        address: v,
        abi: art("CollateralVault").abi,
        functionName: "startUnwinds",
        args: [16n],
      })
    );
    await write(`${v}.peg`, v, art("CollateralVault").abi, "maintainPeg");
    const buffer = await vread(v, "operatingBuffer");
    await write(`${v}.recoveryApprove`, hollar, erc20, "approve", [buffer, 100n * 10n ** 18n]);
    await write(`${v}.recoverMain`, buffer, art("PropellerOperatingBuffer").abi,
      "fundPosition", [0n, 100n * 10n ** 18n]);
  }
  await write("recoverSource", hollar, erc20, "transfer", [
    source,
    100n * 10n ** 18n,
  ]);
  await write("resume", source, art("SubLoop").abi, "unpauseEmergency");
  for (const v of [btc, ethVault])
    await write(`${v}.start`, v, art("CollateralVault").abi, "startUnwinds", [
      16n,
    ]);
  for (let i = 0; i < 80; i++) {
    if (
      (await vread(ethVault, "totalQueuedDebt")) === 0n &&
      (await vread(btc, "totalQueuedDebt")) === 0n
    )
      break;
    await write(`repay${i}`, source, art("SubLoop").abi, "pokeRepay");
    for (const v of [ethVault, btc])
      await write(
        `${v}.settle${i}`,
        v,
        art("CollateralVault").abi,
        "pokeSettle"
      );
  }
  r.campaignPayouts ??= [];
  for (const [i, p] of positions.entries()) {
    if (r.campaignPayouts.some(x => x.vault === p.v && x.user === p.who.address)) continue;
    const id = BigInt(i % 2),
      request = await vread(p.v, "redemptions", [id]);
    assert.equal(request[5], request[3], `user ${i}: unpaid Main debt`);
    const before = await read(token(p.id), erc20, "balanceOf", [p.who.address]);
    await write(
      `user${i}.claim`,
      p.v,
      art("CollateralVault").abi,
      "claim",
      [id, p.who.address],
      p.who
    );
    const paid =
      (await read(token(p.id), erc20, "balanceOf", [p.who.address])) - before;
    assert.equal(paid, request[2]);
    assert.ok(paid >= p.amount);
    r.campaignPayouts.push({
      vault: p.v,
      user: p.who.address,
      deposited: p.amount,
      promised: request[2],
      paid,
    });
    save();
  }
  for (const [i, p] of positions.entries()) {
    const buffer = await vread(p.v, "operatingBuffer");
    await write(`user${i}.claimBuffer`, buffer, art("PropellerOperatingBuffer").abi,
      "claimBuffer", [BigInt(i % 2)]);
  }
  for (const v of [ethVault, btc])
    assert.equal(await vread(v, "totalQueuedCollateral"), 0n);
  r.checks.nativeFourPublicPositionsPaidInFull = true;
  r.status = "native-multi-user-multi-vault-campaign-passed";
  r.campaignLimitations = [
    "Fork-only route adapter, production adapter not supplied",
    "Donated PRIME fixture tests harvest execution, not realized yield",
    "Explicit external HOLLAR donations for swap friction and recovery",
    "Seven-day native time advance; 90-day paths are separate modeled tests",
  ];
  delete r.campaignError;
  save();
  console.log("NATIVE CAMPAIGN PASS", FILE);
} catch (e) {
  r.campaignError = e.stack ?? String(e);
  save();
  console.error(e);
  process.exitCode = 1;
} finally {
  await api.disconnect();
}
