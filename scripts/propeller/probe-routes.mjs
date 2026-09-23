// Local-fork diagnostics. Zero-minimum calls are eth_call/dry-run quotes only.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const { parseAbi } = createRequire(import.meta.url)("viem");

export async function probeRoutes({
  api,
  pub,
  admin,
  adapter,
  adapterAbi,
  prime,
  hollar,
  pool,
  poolAbi,
  erc20,
  token,
  write,
  read,
}) {
  const abi = parseAbi([
    "function getPriceOracle() view returns(address)",
    "function getAssetPrice(address) view returns(uint256)",
    "function getSourceOfAsset(address) view returns(address)",
    "function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)",
    "function owner() view returns(address)",
    "function allowance(address,address) view returns(uint256)",
  ]);
  const provider = await read(pool, poolAbi, "ADDRESSES_PROVIDER");
  const oracle = await read(provider, abi, "getPriceOracle");
  const assets = Object.fromEntries(
    [
      [43, prime, 6],
      [222, hollar, 18],
      [34, token(34), 18],
      [1000765, token(1000765), 18],
    ].map(([id, address, decimals]) => [id, { id, address, decimals }])
  );
  for (const a of Object.values(assets)) {
    a.price = await read(oracle, abi, "getAssetPrice", [a.address]);
    await write(`probe.approve${a.id}`, a.address, erc20, "approve", [
      adapter,
      2n ** 128n - 1n,
    ]);
  }
  const aPrime = (await read(pool, poolAbi, "getReserveData", [prime]))
    .aTokenAddress;
  assets[1043] = { ...assets[43], id: 1043, address: aPrime };
  const header = await api.rpc.chain.getHeader();
  const result = {
    block: header.number.toString(),
    hash: header.hash.toHex(),
    oracle,
    primeOracleSource: await read(oracle, abi, "getSourceOfAsset", [prime]),
    prices: assets,
    pool143: (await api.query.stableswap.pools(143)).toJSON(),
    pegs143: (await api.query.stableswap.poolPegs(143)).toJSON(),
    rows: [],
    executions: [],
    limitation:
      "One pinned pool state. Dry-run quotes do not establish replenishment, sustained throughput or future fills.",
  };
  result.primeOracleRound = await read(
    result.primeOracleSource,
    abi,
    "latestRoundData"
  );
  result.primeOracleOwner = await read(result.primeOracleSource, abi, "owner");
  const who = (
    await api.call.evmAccountsApi.accountId(admin.address)
  ).toString();
  const routes = [
    [
      222,
      1043,
      [
        { pool: { Stableswap: 143 }, assetIn: 222, assetOut: 43 },
        { pool: { Aave: null }, assetIn: 43, assetOut: 1043 },
      ],
    ],
    [
      1043,
      222,
      [
        { pool: { Aave: null }, assetIn: 1043, assetOut: 43 },
        { pool: { Stableswap: 143 }, assetIn: 43, assetOut: 222 },
      ],
    ],
    [43, 34],
    [43, 1000765],
    [34, 222],
    [1000765, 222],
    [222, 43],
    [43, 222],
  ];
  async function quote(input, output, amount, minimum, hops) {
    if (!hops)
      return (
        await pub.simulateContract({
          account: admin,
          address: adapter,
          abi: adapterAbi,
          functionName: "sell",
          args: [
            assets[input].address,
            assets[output].address,
            amount,
            minimum,
            "0x",
          ],
          gas: 12000000n,
        })
      ).result;
    const q = await api.call.dryRunApi.dryRunCall(
      { system: { Signed: who } },
      api.tx.router.sell(
        input,
        output,
        amount.toString(),
        minimum.toString(),
        hops
      ),
      4
    );
    assert.ok(q.isOk, `dry-run API failed: ${q}`);
    assert.ok(
      q.asOk.executionResult.isOk,
      `route rejected: ${q.asOk.executionResult}`
    );
    const event = q.asOk.emittedEvents.find(
      (e) => e.section === "router" && e.method === "Executed"
    );
    assert.ok(event, "missing router execution event");
    return BigInt(event.data[3].toString());
  }
  for (const [input, output, hops] of routes) {
    for (const dollars of [1, 10, 25, 100, 250, 500, 1000, 2500, 5000]) {
      const a = assets[input],
        b = assets[output];
      const amount =
        (BigInt(dollars) * 100000000n * 10n ** BigInt(a.decimals)) / a.price;
      const fair =
        (amount * a.price * 10n ** BigInt(b.decimals)) /
        (b.price * 10n ** BigInt(a.decimals));
      const row = {
        input,
        output,
        dollars,
        amount,
        fair,
        kind: hops ? "native-loop" : "HydraAugustus.sell",
      };
      try {
        row.outputAmount = await quote(input, output, amount, 0n, hops);
        row.oracleLossBps =
          Number(((fair - row.outputAmount) * 1000000n) / fair) / 100;
        row.minOut100bps = (fair * 9900n) / 10000n;
        try {
          const strict = await quote(
            input,
            output,
            amount,
            row.minOut100bps,
            hops
          );
          assert.equal(strict, row.outputAmount);
          row.strict100bps = true;
        } catch (error) {
          row.strict100bps = false;
          row.strictError = String(error).slice(0, 500);
        }
      } catch (error) {
        row.error = String(error).slice(0, 500);
      }
      result.rows.push(row);
      console.log(
        "ROUTE_QUOTE",
        JSON.stringify(row, (_, v) =>
          typeof v === "bigint" ? v.toString() : v
        )
      );
    }
  }
  // Every submitted transaction retains its oracle-relative floor; rejected
  // routes remain rejected. No pool/oracle storage is overwritten for a pass.
  for (const [input, output, hops] of routes) {
    if (hops) continue;
    const a = assets[input],
      b = assets[output],
      amount = (100n * 100000000n * 10n ** BigInt(a.decimals)) / a.price;
    const fair =
      (amount * a.price * 10n ** BigInt(b.decimals)) /
      (b.price * 10n ** BigInt(a.decimals));
    const minimum = (fair * 9900n) / 10000n;
    let quoted;
    try {
      quoted = await quote(input, output, amount, minimum);
    } catch (error) {
      result.executions.push({
        input,
        output,
        submitted: false,
        reason: String(error).slice(0, 500),
      });
      continue;
    }
    await assert.rejects(() => quote(input, output, amount, quoted + 1n));
    const before = await read(b.address, erc20, "balanceOf", [admin.address]);
    await write(
      `probe.execute${input}to${output}`,
      adapter,
      adapterAbi,
      "sell",
      [a.address, b.address, amount, minimum, "0x"]
    );
    const received =
      (await read(b.address, erc20, "balanceOf", [admin.address])) - before;
    assert.ok(received >= minimum);
    for (const address of [a.address, b.address])
      assert.equal(await read(address, erc20, "balanceOf", [adapter]), 0n);
    result.executions.push({
      input,
      output,
      submitted: true,
      amount,
      minimum,
      received,
      custodyEmpty: true,
      dispatchAllowance: await read(a.address, abi, "allowance", [
        adapter,
        "0x0000000000000000000000000000000000000401",
      ]),
    });
  }
  return result;
}
