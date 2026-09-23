// Local-only LTV reduction exercises Main resizing without changing AMM prices.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
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
} = require("viem");
const { mnemonicToAccount } = require("viem/accounts");
const port = Number(process.env.PROPELLER_LOCAL_PORT || 8145);
assert.ok(Number.isInteger(port) && port > 0 && port < 65536);
const rpc = `http://127.0.0.1:${port}`,
  file = process.argv[2];
const result = JSON.parse(readFileSync(file));
assert.equal(result.rpc, rpc);
assert.equal(result.status, "native-multi-user-multi-vault-campaign-passed");
const art = (n) =>
  JSON.parse(
    readFileSync(
      new URL(`../../propeller-vault/out/${n}.sol/${n}.json`, import.meta.url)
    )
  );
const abi = parseAbi([
  "function ADDRESSES_PROVIDER() view returns(address)",
  "function getPoolConfigurator() view returns(address)",
  "function configureReserveAsCollateral(address,uint256,uint256,uint256)",
  "function balanceOf(address) view returns(uint256)",
]);
const poolAbi = JSON.parse(
  readFileSync(
    new URL(
      "../../deployments/hydration/Pool-Implementation.json",
      import.meta.url
    )
  )
).abi;
const admin = mnemonicToAccount(
  "test test test test test test test test test test test junk"
);
const gov = "0xAa7e0000000000000000000000000000000Aa7e0";
const chain = {
  id: result.fork.chainId,
  name: "Local only",
  nativeCurrency: { name: "WETH", symbol: "WETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
};
const pub = createPublicClient({
  chain,
  transport: http(rpc, { timeout: 180000 }),
  pollingInterval: 1000,
  cacheTime: 0,
});
const wallet = createWalletClient({
  account: admin,
  chain,
  transport: http(rpc, { timeout: 180000 }),
});
const ws = new WsProvider(`ws://127.0.0.1:${port}`, 2500, {}, 180000);
const api = await ApiPromise.create({ provider: ws, noInitWarn: true });
const { vault, source, buffer } = result.addresses;
const { pool, collateral, aEth, aPrime, hollarDebt } = result.market;
const read = (address, abi, functionName, args = []) =>
  pub.readContract({ address, abi, functionName, args });
const save = () =>
  writeFileSync(
    file,
    JSON.stringify(
      result,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2
    ) + "\n"
  );
async function send(address, abi, functionName, args = []) {
  const options = {
    address,
    abi,
    functionName,
    args,
    gas: 12000000n,
    gasPrice: (await pub.getGasPrice()) * 2n,
    type: "legacy",
  };
  await pub.simulateContract({ ...options, account: admin });
  let hash;
  for (let retry = 0; ; retry++) {
    try {
      hash = await wallet.writeContract({
        ...options,
        gasPrice: options.gasPrice + BigInt(retry),
      });
      break;
    } catch (e) {
      if (retry >= 3 || !String(e).includes("Expected input with 32 bytes"))
        throw e;
    }
  }
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 240000 });
  assert.equal(r.status, "success");
  result.nativeResize.calls.push({ functionName, hash, gasUsed: r.gasUsed });
  save();
}
async function risk(configurator, ltv, lt, bonus) {
  const data = encodeFunctionData({
    abi,
    functionName: "configureReserveAsCollateral",
    args: [collateral, ltv, lt, bonus],
  });
  const call = api.tx.dispatcher.dispatchAsAaveManager(
    api.tx.evm.call(
      gov,
      configurator,
      data,
      "0",
      "2000000",
      ((await pub.getGasPrice()) * 2n).toString(),
      null,
      null,
      [],
      []
    )
  );
  const body = hexToU8a(call.method.toHex()),
    hash = blake2AsHex(body),
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
  const actual = (await read(pool, poolAbi, "getReserveData", [collateral]))
    .configuration.data;
  assert.equal(actual & 65535n, ltv);
}
try {
  await ws.send("dev_setBlockBuildMode", ["Instant"]);
  assert.equal(
    await read(vault, art("CollateralVault").abi, "queueHead"),
    await read(vault, art("CollateralVault").abi, "queueTail")
  );
  const provider = await read(pool, abi, "ADDRESSES_PROVIDER"),
    configurator = await read(provider, abi, "getPoolConfigurator");
  const config = (await read(pool, poolAbi, "getReserveData", [collateral]))
    .configuration.data;
  const ltv = config & 65535n,
    lt = (config >> 16n) & 65535n,
    bonus = (config >> 32n) & 65535n;
  assert.ok(ltv > 1500n);
  const state = async () => ({
    mainDebt: await read(hollarDebt, abi, "balanceOf", [vault]),
    loopDebt: await read(hollarDebt, abi, "balanceOf", [source]),
    prime: await read(aPrime, abi, "balanceOf", [source]),
    collateral: await read(aEth, abi, "balanceOf", [vault]),
    ownedCash: await read(buffer, art("PropellerMainDebt").abi, "ownedCash"),
    target: await read(vault, art("CollateralVault").abi, "deleverTarget"),
  });
  result.nativeResize = {
    scope:
      "Remaining seed position, local governance LTV reduction by 1500bp, not a live collateral-price crash. Existing campaign recovery cash is recorded.",
    calls: [],
    preDrain: await state(),
    originalLtv: ltv,
    newLtv: ltv - 1500n,
  };
  save();
  await send(source, art("SubLoop").abi, "setTranches", [
    1000n * 10n ** 18n,
    900n * 10n ** 6n,
  ]);
  assert.equal(await read(source, art("SubLoop").abi, "dcaSlippagePpm"), 10000);
  result.nativeResize.localCandidateTranches = {
    hollar: "1000",
    prime: "900",
    productionApproved: false,
  };
  const vaults = [vault, result.addresses.tbtcVault];
  result.nativeResize.preDrainSourceClaims = [];
  for (const v of vaults)
    result.nativeResize.preDrainSourceClaims.push({
      vault: v,
      amount: await read(source, art("SubLoop").abi, "pendingUnwindOf", [v]),
    });
  save();
  for (let i = 0; i < 80; i++) {
    if ((await read(source, art("SubLoop").abi, "unwindTargetEquity")) === 0n)
      break;
    await send(source, art("SubLoop").abi, "pokeRepay");
    for (const v of vaults)
      await send(v, art("CollateralVault").abi, "pokeSettle");
  }
  result.nativeResize.latePayouts = [];
  for (const v of vaults) {
    assert.equal(
      await read(source, art("SubLoop").abi, "pendingUnwindOf", [v]),
      0n,
      "old claims not drained"
    );
    const ledger = await read(v, art("CollateralVault").abi, "mainDebt");
    for (let id = 0n; id < 2n; id++) {
      const position = await read(
        ledger,
        art("PropellerMainDebt").abi,
        "positions",
        [id + 1n]
      );
      const owner = position[4];
      const before = await read(result.market.hollar, abi, "balanceOf", [
        owner,
      ]);
      await send(ledger, art("PropellerMainDebt").abi, "claimSurplus", [id]);
      const paid =
        (await read(result.market.hollar, abi, "balanceOf", [owner])) - before;
      assert.equal(paid, position[2]);
      result.nativeResize.latePayouts.push({ vault: v, id, owner, paid });
      save();
    }
  }
  result.nativeResize.before = await state();
  save();
  await risk(configurator, ltv - 1500n, lt, bonus);
  try {
    await send(vault, art("CollateralVault").abi, "rebalance");
    result.nativeResize.scheduled = await state();
    save();
    assert.ok(
      result.nativeResize.scheduled.target > 0n,
      "no Main shrink scheduled"
    );
    for (let i = 0; i < 80; i++) {
      await send(source, art("SubLoop").abi, "pokeRepay");
      await send(vault, art("CollateralVault").abi, "pokeSettle");
      if (
        (await read(vault, art("CollateralVault").abi, "deleverTarget")) === 0n
      )
        break;
    }
    const after = await state(),
      before = result.nativeResize.before;
    assert.equal(after.target, 0n);
    assert.ok(after.mainDebt < before.mainDebt);
    assert.ok(after.prime < before.prime);
    assert.ok(
      after.collateral >= before.collateral,
      "Main resize consumed user collateral"
    );
    result.nativeResize.after = after;
    result.nativeResize.passed = true;
  } finally {
    await risk(configurator, ltv, lt, bonus);
    result.nativeResize.ltvRestored = true;
    save();
  }
} catch (e) {
  result.nativeResize ??= {};
  result.nativeResize.error = String(e);
  save();
  throw e;
} finally {
  await api.disconnect();
}
