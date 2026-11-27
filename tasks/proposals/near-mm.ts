// @ts-nocheck
//
// NEAR money-market listing (Nov 2026, Root track) — fourth of the hype/zec/spy-mm series.
//
// NEAR (1001358, 24 decimals) is live in the Omnipool as a raw token. This lists it in
// the main market with the HYPE/ZEC/SPY parameters (LTV 70 / LT 75 / bonus 7%,
// borrowable, reserve factor 20%, SOL's rate strategy), priced by the DIA NEAR/USD
// adapter deployed 2026-11-04, caps $1M supply / $500k borrow converted at the feed
// (reservesConfigs.ts `strategyNEAR`).
//
// One enactment batch:
//   1. init-reserve NEAR: setAssetSources, initReserves, configureReserves,
//      liquidation protocol fee                                 (aave manager)
//   2. assetRegistry.register aNEAR (1013) at the predicted aToken address,
//      multiTransactionPayment.addCurrency                     (root)
//   3. routes HDX/WETH -> aNEAR (fee currency pricing), and a liquidation route
//      between NEAR and every reserve outside the Omnipool          (root)
//   4. ice.updateRouting(AaveWrap(NEAR, aNEAR), Included) so the ICE solver can
//      route intents through the new wrap
//   5. router.sellAll NEAR -> aNEAR for the treasury's whole free NEAR (dispatchAsTreasury)
//
// The aToken address is predicted from the PoolConfigurator nonce (+3 per reserve
// initialised ahead of this one; ATOKEN_NONCE overrides). The fee-currency fallback
// price is read from the HDX and NEAR feeds at build time.
//
// dispatchAsTreasury and dispatchAsAaveManager swallow inner failures, so the dry-run
// must confirm the ReserveInitialized/config events and the treasury's aNEAR balance,
// not just BatchCompleted.
//
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
  dispatchAsTreasury,
} from "../../helpers/hydration-proposal.js";
import {
  ConfigNames,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, getPoolAddressesProvider, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

const HDX = 0;
const DOT = 5;
const USDT = 10;
const VDOT = 15;
const WETH = 20;
const USDC = 22;
const ETH = 34;
const PRIME = 43;
const EURC = 44;
const APYUSD = 46;
const HOLLAR = 222;
const SOL = 1000752;
const NEAR = 1001358;
const aNEAR = 1013;
// Wormhole USDT/USDC reserves, both constituents of 3-Pool-MRL (105)
const USDC_WH = 21;
const USDT_WH = 23;
const MRL_POOL = 105;

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
const PRIME_POOL = 143;
const APYUSD_POOL = 146;
const HEURC_POOL = 10044;
// HOLLAR-paired shares listed as collateral: H-pools, 2-Pool-PRIME/apyUSD/HEURC/BIL, 3-Pool-MRL
const HOLLAR_POOLS = [110, 111, 112, 113, PRIME_POOL, APYUSD_POOL, HEURC_POOL, 10055, 105];

const NEAR_ED = "2074688796680497925311"; // aNEAR ED = NEAR ED (aPRIME precedent)
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";
const NEAR_FEED = "0x645ba3e65038A7785b1b7D0A67cb90fe8211843E";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(104, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

task(`near-mm`, `NEAR money-market listing + aNEAR registration + ICE routing + treasury NEAR -> aNEAR`).setAction(
  async function (_, hre) {
    const { utils, BigNumber } = hre.ethers;
    const network = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[network];
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const api = await getApi();
    const hydrationTx = api.tx;
    const poolAddressesProvider = await getPoolAddressesProvider();

    const deployer = await poolAddressesProvider.getPoolConfigurator();
    const liveNonce = await hre.ethers.provider.getTransactionCount(deployer);
    const nonce = process.env.ATOKEN_NONCE ? Number(process.env.ATOKEN_NONCE) : liveNonce;
    const aToken = utils.getContractAddress({ from: deployer, nonce });
    console.log(`PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""} -> aNEAR ${aToken}`);

    // 1. reserve init + config, all from strategyNEAR
    await hre.run("init-reserve", { symbol: "NEAR", batch: true });
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. aToken registry entry + fee currency.
    // Fee price = aNEAR raw units per HDX raw unit (NEAR 24 dec, HDX 12 dec, so 1e12 ×
    // 1e18 FixedU128 = 1e30); it is only the fallback for when the route oracle has no price.
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const nearUsd = await feed(NEAR_FEED).latestAnswer();
    const feePrice = hdxUsd.mul(BigNumber.from(10).pow(30)).div(nearUsd).toString();
    console.log(`HDX/USD ${hdxUsd} NEAR/USD ${nearUsd} (8 dec) -> aNEAR fee price ${feePrice}`);

    const rootTxs = [
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: aNEAR,
          name: "aNEAR",
          assetType: "Erc20",
          existentialDeposit: NEAR_ED,
          symbol: "aNEAR",
          decimals: 24,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      ),
      hydrationTx.multiTransactionPayment.addCurrency(aNEAR, feePrice),
    ];

    // 3. routes
    const routes = [
      // fee-currency pricing of aNEAR (HDX fallback, EVM fee pricing)
      [HDX, aNEAR, [omni(HDX, NEAR), aave(NEAR, aNEAR)]],
      [WETH, aNEAR, [...WETH_TO_GETH, omni(GETH, NEAR), aave(NEAR, aNEAR)]],
      // liquidations: NEAR collateral vs debt assets outside the Omnipool (HYPE/ZEC/SPY are in it: no route)
      [USDC, NEAR, [aave(USDC, AUSDC), ss(110, AUSDC, HOLLAR), omni(HOLLAR, NEAR)]],
      [USDT, NEAR, [aave(USDT, AUSDT), ss(111, AUSDT, HOLLAR), omni(HOLLAR, NEAR)]],
      [DOT, NEAR, [aave(DOT, ADOT), omni(ADOT, NEAR)]],
      [ETH, NEAR, [aave(ETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH), omni(GETH, NEAR)]],
      [NEAR, VDOT, [omni(NEAR, ADOT), ss(GDOT_POOL, ADOT, VDOT)]],
      [NEAR, PRIME, [omni(NEAR, HOLLAR), ss(PRIME_POOL, HOLLAR, PRIME)]],
      [NEAR, SOL, [omni(NEAR, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
      [NEAR, EURC, [omni(NEAR, HOLLAR), ss(HEURC_POOL, HOLLAR, AEURC), aave(AEURC, EURC)]],
      [NEAR, APYUSD, [omni(NEAR, HOLLAR), ss(APYUSD_POOL, HOLLAR, APYUSD)]],
      [NEAR, USDC_WH, [omni(NEAR, HOLLAR), ss(MRL_POOL, HOLLAR, USDC_WH)]],
      [NEAR, USDT_WH, [omni(NEAR, HOLLAR), ss(MRL_POOL, HOLLAR, USDT_WH)]],
      // liquidations: NEAR debt vs share collateral
      [NEAR, GDOT_POOL, [omni(NEAR, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)]],
      [NEAR, GETH_POOL, [omni(NEAR, GETH), aave(GETH, GETH_POOL)]],
      [NEAR, GSOL_POOL, [omni(NEAR, GSOL), aave(GSOL, GSOL_POOL)]],
      [NEAR, THREE_POOL, [omni(NEAR, HOLLAR), ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)]],
      ...HOLLAR_POOLS.map((p) => [NEAR, p, [omni(NEAR, HOLLAR), ss(p, HOLLAR, p)]]),
      // no route: SIGIL (no venue, no supply) and WBTC (frozen; pool 101 has no Omnipool leg)
      // default Omnipool hop covers HOLLAR, PAXG, tBTC, HYPE, ZEC, SPY
    ];
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // 4. ICE solver routing: opt the new Aave wrap in
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [NEAR, aNEAR] }, "Included"));

    // 5. treasury's whole free NEAR -> aNEAR (supply via the router's Aave pool)
    rootTxs.push(
      await dispatchAsTreasury(hydrationTx.router.sellAll(NEAR, aNEAR, 0, [aave(NEAR, aNEAR)]))
    );

    const preimage = await generateProposalV2([...txs, ...rootTxs], false);
    const decoder = new ProposalDecoder(hre);
    await decoder.init();
    console.log("submit preimage:");
    console.log(preimage.toHex());
    decoder.printTree(decoder.transformCall(preimage.toHuman()));
    console.log("hash:", preimage.hash.toHex());
    console.log("length:", preimage.encodedLength);
  }
);
