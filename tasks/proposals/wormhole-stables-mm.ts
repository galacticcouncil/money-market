// @ts-nocheck
//
// Wormhole stables money-market listing (Oct 2026, Root track) — step 1 of moving the
// HOLLAR venues from the Asset Hub stables (USDT 10 / USDC 22) to the Wormhole NTT
// stables (USDT 23 / USDC 21). Reserves only: no H-pools, HSM or treasury legs.
//
// Both reserves mirror the native stables (strategyUSDC: stables80 curve, LTV 80 / LT 90 /
// bonus 3%, RF 10%, Stablecoins eMode) with caps 2M supply / 1M borrow and the native
// stables' USDT/USD and USDC/USD feeds (reservesConfigs.ts `strategyUSDCwh`).
//
// One enactment batch:
//   1. init-reserve USDT.WH then USDC.WH, both into Stablecoins eMode   (aave manager)
//   2. registry names: the three USDT/USDC flavors become "(Polkadot)", "(Wormhole)",
//      "(Snowbridge)"; the native aTokens become "Supplied … (Polkadot)". Symbols stay. (root)
//   3. assetRegistry.register aUSDT.wh (1023) / aUSDC.wh (1021) at the predicted aToken
//      addresses, multiTransactionPayment.addCurrency                      (root)
//   4. routes HDX/WETH -> new aTokens (fee currency pricing), and a liquidation route
//      between each Wormhole stable and every reserve (neither is in the Omnipool, so
//      the default one-hop route never applies); HOLLAR via pool 105 is the hub  (root)
//   5. ice.updateRouting(AaveWrap(stable, aToken), Included) for both     (root)
//
// The aToken addresses are predicted from the PoolConfigurator nonce (+3 per reserve
// initialised; USDT.WH at nonce, USDC.WH at nonce + 3; ATOKEN_NONCE overrides). The
// fee-currency fallback prices are read from the HDX and stable feeds at build time.
//
// dispatchAsAaveManager swallows inner failures, so the dry-run must confirm the
// ReserveInitialized/config events, not just BatchCompleted.
//
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import {
  ConfigNames,
  getReserveAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { addTransaction, getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, getPoolAddressesProvider, getPoolConfiguratorProxy, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

const HDX = 0;
const DOT = 5;
const USDT = 10;
const VDOT = 15;
const WETH = 20;
const USDC_WH = 21;
const USDC = 22;
const USDT_WH = 23;
const ETH = 34;
const PAXG = 39;
const PRIME = 43;
const EURC = 44;
const APYUSD = 46;
const HOLLAR = 222;
const SOL = 1000752;
const TBTC = 1000765;
const USDC_SNOWBRIDGE = 1000766;
const USDT_SNOWBRIDGE = 1000767;
const HYPE = 1001355;
const ZEC = 1001357;
const aUSDC_WH = 1021;
const aUSDT_WH = 1023;

// aTokens, GIGA tokens and the stableswap shares the routes pass through
const ADOT = 1001;
const AUSDT = 1002;
const AUSDC = 1003;
const AETH = 1007;
const ASOL = 1009;
const AEURC = 1044;
const GETH = 420;
const GETH_POOL = 4200;
const GDOT_POOL = 690;
const GSOL = 9001;
const GSOL_POOL = 90001;
const THREE_POOL = 103;
const WH_POOL = 105; // 3-Pool-MRL: USDC.wh / USDT.wh / HOLLAR
const PRIME_POOL = 143;
const APYUSD_POOL = 146;
const HEURC_POOL = 10044;
// HOLLAR-paired shares listed as collateral: H-pools, 2-Pool-PRIME/apyUSD/HEURC/BIL (3-Pool-MRL is direct)
const HOLLAR_POOLS = [110, 111, 112, 113, PRIME_POOL, APYUSD_POOL, HEURC_POOL, 10055];

const ATOKEN_ED = "22409"; // = aUSDT (1002) / aUSDC (1003)
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";
const USDT_FEED = "0x8b0DDfB8F56690eAde9ECa23a7d90E153C268d5B";
const USDC_FEED = "0x17711BE5D63B2Fe8A2C379725DE720773158b954";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(104, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

// HOLLAR -> reserve, the tails the native stables' stored routes use after their HOLLAR hop.
// No route: WBTC (frozen; pool 101 has no Omnipool leg) and SIGIL (no venue, no supply).
const FROM_HOLLAR = [
  [USDT, [ss(111, HOLLAR, AUSDT), aave(AUSDT, USDT)]],
  [USDC, [ss(110, HOLLAR, AUSDC), aave(AUSDC, USDC)]],
  [DOT, [omni(HOLLAR, ADOT), aave(ADOT, DOT)]],
  [VDOT, [omni(HOLLAR, ADOT), ss(GDOT_POOL, ADOT, VDOT)]],
  [GDOT_POOL, [omni(HOLLAR, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)]],
  [ETH, [omni(HOLLAR, GETH), aave(GETH, GETH_POOL), ss(GETH_POOL, GETH_POOL, AETH), aave(AETH, ETH)]],
  [GETH_POOL, [omni(HOLLAR, GETH), aave(GETH, GETH_POOL)]],
  [SOL, [omni(HOLLAR, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
  [GSOL_POOL, [omni(HOLLAR, GSOL), aave(GSOL, GSOL_POOL)]],
  [TBTC, [omni(HOLLAR, TBTC)]],
  [PAXG, [omni(HOLLAR, PAXG)]],
  [HYPE, [omni(HOLLAR, HYPE)]],
  [ZEC, [omni(HOLLAR, ZEC)]],
  [THREE_POOL, [ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)]],
  [PRIME, [ss(PRIME_POOL, HOLLAR, PRIME)]],
  [APYUSD, [ss(APYUSD_POOL, HOLLAR, APYUSD)]],
  [EURC, [ss(HEURC_POOL, HOLLAR, AEURC), aave(AEURC, EURC)]],
  [HOLLAR, []],
  ...HOLLAR_POOLS.map((p) => [p, [ss(p, HOLLAR, p)]]),
];

task(`wormhole-stables-mm`, `Wormhole USDT/USDC money-market listing + registry names + aToken registration + ICE routing`).setAction(
  async function (_, hre) {
    const { utils, BigNumber } = hre.ethers;
    const network = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[network];
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const api = await getApi();
    const hydrationTx = api.tx;
    const poolAddressesProvider = await getPoolAddressesProvider();
    const poolConfigurator = await getPoolConfiguratorProxy();

    const deployer = await poolAddressesProvider.getPoolConfigurator();
    const liveNonce = await hre.ethers.provider.getTransactionCount(deployer);
    const nonce = process.env.ATOKEN_NONCE ? Number(process.env.ATOKEN_NONCE) : liveNonce;
    const aUSDTwh = utils.getContractAddress({ from: deployer, nonce });
    const aUSDCwh = utils.getContractAddress({ from: deployer, nonce: nonce + 3 });
    console.log(
      `PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""}` +
        ` -> aUSDT.wh ${aUSDTwh}, aUSDC.wh ${aUSDCwh}`
    );

    // 1. reserve init + config from strategyUSDTwh / strategyUSDCwh, then Stablecoins eMode
    for (const symbol of ["USDT.WH", "USDC.WH"]) {
      await hre.run("init-reserve", { symbol, batch: true });
    }
    for (const symbol of ["USDT.WH", "USDC.WH"]) {
      addTransaction(
        await poolConfigurator.populateTransaction.setAssetEModeCategory(
          await getReserveAddress(config, symbol),
          config.EModes["StableEMode"].id
        )
      );
    }
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. registry names; symbols are untouched
    const rename = (id, name) => hydrationTx.assetRegistry.update(id, name, null, null, null, null, null, null, null);
    const rootTxs = [
      rename(USDT, "Tether (Polkadot)"),
      rename(USDC, "USDC (Polkadot)"),
      rename(USDT_SNOWBRIDGE, "Tether (Snowbridge)"),
      rename(USDC_SNOWBRIDGE, "USDC (Snowbridge)"),
      rename(AUSDT, "Supplied Tether (Polkadot)"),
      rename(AUSDC, "Supplied USDC (Polkadot)"),
    ];

    // 3. aToken registry entries + fee currencies.
    // Fee price = aToken raw units per HDX raw unit (6 dec vs HDX 12 dec, so 1e-6 ×
    // 1e18 FixedU128 = 1e12); it is only the fallback for when the route oracle has no price.
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const aTokens = [
      { id: aUSDT_WH, name: "Supplied Tether (Wormhole)", symbol: "aUSDT", address: aUSDTwh, feed: USDT_FEED },
      { id: aUSDC_WH, name: "Supplied USDC (Wormhole)", symbol: "aUSDC", address: aUSDCwh, feed: USDC_FEED },
    ];
    for (const t of aTokens) {
      const usd = await feed(t.feed).latestAnswer();
      const feePrice = hdxUsd.mul(BigNumber.from(10).pow(12)).div(usd).toString();
      console.log(`HDX/USD ${hdxUsd} ${t.symbol}/USD ${usd} (8 dec) -> ${t.name} fee price ${feePrice}`);
      rootTxs.push(
        hydrationTx.assetRegistry.register(
          ...Object.values({
            id: t.id,
            name: t.name,
            assetType: "Erc20",
            existentialDeposit: ATOKEN_ED,
            symbol: t.symbol,
            decimals: 6,
            location: location(t.address),
            xcmRateLimit: null,
            isSufficient: true,
          })
        ),
        hydrationTx.multiTransactionPayment.addCurrency(t.id, feePrice)
      );
    }

    // 4. routes
    const routes = [
      // fee-currency pricing of the new aTokens (HDX fallback, EVM fee pricing)
      [HDX, aUSDT_WH, [omni(HDX, HOLLAR), ss(WH_POOL, HOLLAR, USDT_WH), aave(USDT_WH, aUSDT_WH)]],
      [HDX, aUSDC_WH, [omni(HDX, HOLLAR), ss(WH_POOL, HOLLAR, USDC_WH), aave(USDC_WH, aUSDC_WH)]],
      [WETH, aUSDT_WH, [...WETH_TO_GETH, omni(GETH, HOLLAR), ss(WH_POOL, HOLLAR, USDT_WH), aave(USDT_WH, aUSDT_WH)]],
      [WETH, aUSDC_WH, [...WETH_TO_GETH, omni(GETH, HOLLAR), ss(WH_POOL, HOLLAR, USDC_WH), aave(USDC_WH, aUSDC_WH)]],
      // liquidations between the two Wormhole stables and between each and every reserve
      [USDC_WH, USDT_WH, [ss(WH_POOL, USDC_WH, USDT_WH)]],
    ];
    for (const stable of [USDT_WH, USDC_WH]) {
      routes.push([stable, WH_POOL, [ss(WH_POOL, stable, WH_POOL)]]);
      for (const [reserve, tail] of FROM_HOLLAR) {
        routes.push([stable, reserve, [ss(WH_POOL, stable, HOLLAR), ...tail]]);
      }
    }
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // 5. ICE solver routing: opt the new Aave wraps in
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [USDT_WH, aUSDT_WH] }, "Included"));
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [USDC_WH, aUSDC_WH] }, "Included"));

    const preimage = await generateProposalV2([...txs, ...rootTxs], false);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    console.log("submit preimage:");
    console.log(preimage.toHex());
    decoder.printTree(decoder.transformCall(preimage.toHuman()));
    console.log("routes:", routes.length);
    console.log("hash:", preimage.hash.toHex());
    console.log("length:", preimage.encodedLength);
  }
);
