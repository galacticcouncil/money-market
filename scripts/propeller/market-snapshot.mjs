// Read-only pinned market inputs for the scenario model. No signing or writes to chain.
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
const require = createRequire(new URL("../../package.json", import.meta.url));
const { ApiPromise, WsProvider } = require("@polkadot/api");
const { blake2AsU8a } = require("@polkadot/util-crypto");
const { createPublicClient, http, parseAbi } = require("viem");
const output = process.argv[2] || "/tmp/propeller-market-snapshot.json";
const api = await ApiPromise.create({
  provider: new WsProvider("wss://hdx.tarn.hydration.cloud"),
  noInitWarn: true,
});
const pub = createPublicClient({
  transport: http("https://hdx.tarn.hydration.cloud", { timeout: 120000 }),
});
const POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";
const abi = JSON.parse(
  readFileSync(
    new URL("../../deployments/lark2/Pool-Implementation.json", import.meta.url)
  )
).abi;
const erc20 = parseAbi([
  "function totalSupply() view returns(uint256)",
  "function balanceOf(address) view returns(uint256)",
  "function decimals() view returns(uint8)",
]);
const token = (id) =>
  `0x${((1n << 32n) + BigInt(id)).toString(16).padStart(40, "0")}`;
try {
  const hash = process.env.SNAPSHOT_BLOCK_HASH
    ? api.registry.createType("Hash", process.env.SNAPSHOT_BLOCK_HASH)
    : await api.rpc.chain.getFinalizedHead();
  const header = await api.rpc.chain.getHeader(hash);
  const blockNumber = BigInt(header.number.toString());
  const at = await api.at(hash);
  const read = (address, abi, functionName, args = []) =>
    pub.readContract({ address, abi, functionName, args, blockNumber });
  const result = {
    timestamp: new Date().toISOString(),
    upstream: "hdx.tarn.hydration.cloud",
    block: blockNumber,
    hash: hash.toHex(),
    runtime: (await api.rpc.state.getRuntimeVersion(hash)).toJSON(),
    markets: {},
    hsm: {},
    pools: {},
    facilitators: [],
  };
  const previousHash = await api.rpc.chain.getBlockHash(blockNumber - 1000n);
  const previous = await api.at(previousHash);
  result.blockTimestampMs = (await at.query.timestamp.now()).toString();
  result.observedBlockSeconds =
    (Number(result.blockTimestampMs) -
      Number(await previous.query.timestamp.now())) /
    1e6;
  result.hollarTotalSupply = await read(HOLLAR, erc20, "totalSupply");
  result.hsm.minArbitrageAmount = at.consts.hsm.minArbitrageAmount.toString();
  const provider = await read(POOL, abi, "ADDRESSES_PROVIDER");
  const oracle = await read(
    provider,
    parseAbi(["function getPriceOracle() view returns(address)"]),
    "getPriceOracle"
  );
  const oracleAbi = parseAbi([
    "function getAssetPrice(address) view returns(uint256)",
  ]);
  const assets = [
    { symbol: "ETH", id: 34 },
    { symbol: "tBTC", id: 1000765 },
    { symbol: "PRIME", id: 43 },
    { symbol: "HOLLAR", id: 222 },
  ];
  for (const { symbol, id } of assets) {
    const address = id === 222 ? HOLLAR : token(id);
    const reserve = await read(POOL, abi, "getReserveData", [address]);
    const configuration = reserve.configuration.data;
    const decimals = Number((configuration >> 48n) & 255n);
    result.markets[symbol] = {
      id,
      address,
      reserve,
      decimals,
      ltvBps: Number(configuration & 65535n),
      ltBps: Number((configuration >> 16n) & 65535n),
      borrowCap: (configuration >> 80n) & ((1n << 36n) - 1n),
      supplyCap: (configuration >> 116n) & ((1n << 36n) - 1n),
      debtCeiling: (configuration >> 212n) & ((1n << 40n) - 1n),
      price: await read(oracle, oracleAbi, "getAssetPrice", [address]),
      supply: await read(reserve.aTokenAddress, erc20, "totalSupply"),
      variableDebt: await read(
        reserve.variableDebtTokenAddress,
        erc20,
        "totalSupply"
      ),
      availableLiquidity: await read(address, erc20, "balanceOf", [
        reserve.aTokenAddress,
      ]),
      asset: (await at.query.assetRegistry.assets(id)).toJSON(),
    };
  }
  const facilitatorAbi = parseAbi([
    "function getFacilitatorsList() view returns(address[])",
    "function getFacilitator(address) view returns((uint128 bucketCapacity,uint128 bucketLevel,string label))",
  ]);
  for (const address of await read(
    HOLLAR,
    facilitatorAbi,
    "getFacilitatorsList"
  )) {
    result.facilitators.push({
      address,
      ...(await read(HOLLAR, facilitatorAbi, "getFacilitator", [address])),
    });
  }
  const hsmBytes = Buffer.concat([
    Buffer.from("modl"),
    Buffer.from(at.consts.hsm.palletId.toU8a()),
    Buffer.alloc(20),
  ]);
  const hsmAccount = api.registry.createType("AccountId", hsmBytes).toString();
  result.hsm.account = hsmAccount;
  result.hsm.collaterals = [];
  for (const [key, value] of await at.query.hsm.collaterals.entries()) {
    const id = key.args[0].toNumber();
    const config = value.unwrap().toJSON();
    const location = (await at.query.assetRegistry.assetLocations(id)).toJSON();
    const info = (await at.query.assetRegistry.assets(id)).toJSON();
    result.hsm.collaterals.push({
      id,
      config,
      info,
      location,
      balance: (
        await at.call.currenciesApi.freeBalance(id, hsmAccount)
      ).toString(),
    });
    const aToken = location.interior.x1[0].accountKey20.key;
    const underlying = await read(
      aToken,
      parseAbi(["function UNDERLYING_ASSET_ADDRESS() view returns(address)"]),
      "UNDERLYING_ASSET_ADDRESS"
    );
    result.hsm.collaterals.at(-1).underlying = {
      address: underlying,
      cashAtAToken: await read(underlying, erc20, "balanceOf", [aToken]),
      decimals: await read(underlying, erc20, "decimals"),
      aTokenTotalSupply: await read(aToken, erc20, "totalSupply"),
    };
  }
  for (const [key, value] of await at.query.stableswap.pools.entries()) {
    const info = value.unwrap().toJSON();
    if (!info.assets.includes(222) && key.args[0].toNumber() !== 143) continue;
    const id = key.args[0].toNumber();
    const poolId = Buffer.alloc(4);
    poolId.writeUInt32LE(id);
    const poolAccount = api.registry
      .createType(
        "AccountId",
        blake2AsU8a(Buffer.concat([Buffer.from("sts"), poolId]), 256)
      )
      .toString();
    const reserves = [];
    for (const assetId of info.assets) {
      reserves.push({
        id: assetId,
        balance: (
          await at.call.currenciesApi.freeBalance(assetId, poolAccount)
        ).toString(),
        info: (await at.query.assetRegistry.assets(assetId)).toJSON(),
      });
    }
    result.pools[id] = {
      info,
      poolAccount,
      reserves,
      pegs: (await at.query.stableswap.poolPegs(id)).toJSON(),
    };
  }
  result.runtimeApis = Object.fromEntries(
    Object.entries(api.call).map(([k, v]) => [k, Object.keys(v)])
  );
  writeFileSync(
    output,
    JSON.stringify(
      result,
      (_, v) => (typeof v === "bigint" ? v.toString() : v),
      2
    ) + "\n"
  );
  console.log(
    "MARKET SNAPSHOT",
    output,
    result.block.toString(),
    result.hsm,
    result.facilitators
  );
} finally {
  await api.disconnect();
}
