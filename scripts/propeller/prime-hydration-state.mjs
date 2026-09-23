// Pinned read-only reference/oracle/bridge checks; no signing or governance writes.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const { ApiPromise, WsProvider } = require("@polkadot/api");
const { createPublicClient, http, parseAbi, keccak256 } = require("viem");
const market = JSON.parse(readFileSync(process.argv[2]));
const file = process.argv[3] || "/tmp/propeller-prime-hydration-state.json";
const api = await ApiPromise.create({
  provider: new WsProvider("wss://hdx.tarn.hydration.cloud"),
  noInitWarn: true,
});
const pub = createPublicClient({
  transport: http("https://hdx.tarn.hydration.cloud", { timeout: 120000 }),
});
const blockNumber = BigInt(market.block);
const result = {
  upstream: market.upstream,
  block: market.block,
  hash: market.hash,
  retrievedAt: new Date().toISOString(),
  oracles: {},
  bridge: {},
  errors: {},
};
const save = () =>
  writeFileSync(
    file,
    JSON.stringify(
      result,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2
    ) + "\n"
  );
const abi = parseAbi([
  "function ADDRESSES_PROVIDER() view returns(address)",
  "function getPriceOracle() view returns(address)",
  "function getSourceOfAsset(address) view returns(address)",
  "function getAssetPrice(address) view returns(uint256)",
  "function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)",
  "function latestAnswer() view returns(int256)",
  "function decimals() view returns(uint8)",
  "function owner() view returns(address)",
  "function isPaused() view returns(bool)",
  "function token() view returns(address)",
  "function chainId() view returns(uint16)",
  "function rateLimitDuration() view returns(uint64)",
  "function getCurrentOutboundCapacity() view returns(uint256)",
  "function getCurrentInboundCapacity(uint16) view returns(uint256)",
  "function oracles(bytes32) view returns(address)",
  "function latestPrices(bytes32) view returns(uint256,uint64,uint64)",
  "function maxPriceAge() view returns(uint64)",
]);
const read = (address, functionName, args = []) =>
  pub.readContract({ address, abi, functionName, args, blockNumber });
try {
  assert.equal(
    (await api.rpc.chain.getBlockHash(blockNumber)).toHex(),
    market.hash
  );
  const at = await api.at(market.hash),
    prime = market.markets.PRIME.address;
  const provider = await read(
    "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38",
    "ADDRESSES_PROVIDER"
  );
  result.aaveOracle = await read(provider, "getPriceOracle");
  result.activeSource = await read(result.aaveOracle, "getSourceOfAsset", [
    prime,
  ]);
  result.price = await read(result.aaveOracle, "getAssetPrice", [prime]);
  result.peg = (await at.query.stableswap.poolPegs(143)).toJSON();
  result.assetLocation = (
    await at.query.assetRegistry.assetLocations(43)
  ).toJSON();
  for (const [name, address] of [
    ["active", result.activeSource],
    ["wormholeCandidate", "0x6e3E9403Cf486af5f2cE0A6b3d7a23ee0e6BC84e"],
    ["legacyMrl", "0x82022F77ae239Ad99bB1F2aC0d8DaFF6Cc976a07"],
    ["dayEma", "0x000001040000000000000000000000de0000002b"],
  ]) {
    const r = { address };
    result.oracles[name] = r;
    for (const fn of ["latestRoundData", "latestAnswer", "decimals", "owner"]) {
      try {
        r[fn] = await read(address, fn);
      } catch (e) {
        r[`${fn}Error`] = String(e).slice(0, 350);
      }
    }
    const code = await pub.getBytecode({ address, blockNumber });
    if (code) r.codeHash = keccak256(code);
    if (r.latestRoundData)
      r.ageSeconds =
        Number(market.blockTimestampMs) / 1000 - Number(r.latestRoundData[3]);
    save();
  }
  result.bridge.address = "0xFCaF4aA069C565d25539028970703F01e47D3E0B";
  for (const fn of [
    "isPaused",
    "token",
    "chainId",
    "rateLimitDuration",
    "getCurrentOutboundCapacity",
    "getCurrentInboundCapacity",
  ]) {
    try {
      result.bridge[fn] = await read(
        result.bridge.address,
        fn,
        fn === "getCurrentInboundCapacity" ? [1] : []
      );
    } catch (e) {
      result.errors[fn] = String(e).slice(0, 400);
    }
  }
  const receiver = result.oracles.wormholeCandidate.owner,
    asset =
      "0x26759f460ee5f743ed66d27c8f2a5623bf39d53ed575955320661e6e13e0e3da";
  result.receiver = { address: receiver };
  for (const fn of ["oracles", "latestPrices", "maxPriceAge", "owner"]) {
    try {
      result.receiver[fn] = await read(
        receiver,
        fn,
        ["oracles", "latestPrices"].includes(fn) ? [asset] : []
      );
    } catch (e) {
      result.errors[`receiver.${fn}`] = String(e).slice(0, 400);
    }
  }
  const replacement = result.receiver.oracles;
  if (replacement) {
    const r = { address: replacement };
    result.oracles.receiverTarget = r;
    for (const fn of ["latestRoundData", "latestAnswer", "decimals", "owner"])
      r[fn] = await read(replacement, fn);
    r.codeHash = keccak256(
      await pub.getBytecode({ address: replacement, blockNumber })
    );
    r.ageSeconds =
      Number(market.blockTimestampMs) / 1000 - Number(r.latestRoundData[3]);
    const event = parseAbi([
      "event PriceUpdated(uint80 indexed roundId,int256 answer,uint256 timestamp)",
    ])[0];
    result.receiverTargetHistory = [];
    // Bounded historical block range; archive event limits differ by provider.
    const first = blockNumber - 201600n;
    for (let from = first; from <= blockNumber; from += 10000n) {
      const to = from + 9999n > blockNumber ? blockNumber : from + 9999n;
      try {
        const logs = await pub.getLogs({
          address: replacement,
          event,
          fromBlock: from,
          toBlock: to,
        });
        result.receiverTargetHistory.push(
          ...logs.map((x) => ({
            block: x.blockNumber,
            hash: x.transactionHash,
            ...x.args,
          }))
        );
      } catch (e) {
        result.errors[`history.${from}`] = String(e).slice(0, 300);
      }
      save();
    }
  }
  result.circuitBreaker = {};
  for (const key of Object.keys(at.query.circuitBreaker).filter((k) =>
    /xcm|global.*(withdraw|limit|asset)/i.test(k)
  )) {
    try {
      const q = at.query.circuitBreaker[key];
      result.circuitBreaker[key] = q.meta.type.isMap
        ? (await q(43)).toJSON()
        : (await q()).toJSON();
    } catch (e) {
      result.errors[key] = String(e).slice(0, 250);
    }
  }
  save();
  console.log(
    JSON.stringify(
      result,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2
    )
  );
} finally {
  await api.disconnect();
}
