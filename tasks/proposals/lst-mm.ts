// @ts-nocheck
//
// wstETH + jitoSOL money-market listing + e-mode re-parameterisation (Nov 2026, Root track).
//
// wstETH (1000809, 18 dec) and jitoSOL (40, 9 dec) are the LST legs of the 2-Pool-GETH (4200)
// and 2-Pool-GSOL (90001) stableswap pools. This lists both in the main market the way vDOT is
// listed next to GDOT: borrowable, reserve factor 20 %, rateStrategyDOT, collateral params =
// GETH's / GSOL's shifted by the vDOT-vs-GDOT deltas, caps = GETH's / GSOL's scaled by the
// vDOT/GDOT cap ratio (reservesConfigs.ts `strategyWSTETH` / `strategyJITOSOL`), and each asset
// joins its e-mode: wstETH -> ETH (3), jitoSOL -> SOL correlated (4). The three LST e-mode
// categories are re-parameterised in the same batch (markets/hydration/index.ts EModes):
// DOT 85/92/4.5 -> 90/95/3, ETH 80/90/4.5 -> 90/95/3, SOL 80/85/4.5 -> 85/90/3.
//
// Pricing mirrors vDOT (fair-value ratio oracle x base USD feed): USDOracleAdapter(wstETH/stETH
// CheckedOracle x DIA ETH/USD) and USDOracleAdapter(jitoSOL/SOL CheckedOracle x DIA SOL/USD) — the
// CheckedOracles that peg the two GIGA pools, so the reserve price and the pool peg never diverge.
// The DIA wstETH/USD feed is not used. Both adapters are deployed separately
// (`deploy-USDOracleAdapter --oracle WSTETH|JITOSOL`); this task reads their addresses from the
// deployment artifacts or from WSTETH_ORACLE / JITOSOL_ORACLE.
//
// One enactment batch:
//   1. aave manager: setAssetSources(both), initReserves(wstETH), initReserves(jitoSOL),
//      configureReserves x2, setLiquidationProtocolFee x2, setEModeCategory x3 (DOT/ETH/SOL),
//      setAssetEModeCategory x2
//   2. root: assetRegistry.register awstETH (1014) / ajitoSOL (1015) at the predicted aToken
//      addresses, multiTransactionPayment.addCurrency for both
//   3. root: routes HDX/WETH -> aToken (fee pricing) and a liquidation route between each new
//      asset and every other reserve (neither asset is in the Omnipool, so the router's default
//      one-hop route never applies: every pair needs a stored route), plus wstETH <-> jitoSOL,
//      plus the missing 2-Pool-GSOL share -> SOL route (no stored route on chain today, so a
//      GSOL-collateral / SOL-debt position had no liquidation path)
//   4. root: ice.updateRouting(AaveWrap(asset, aToken), Included) for both
//
// aToken addresses are predicted from the PoolConfigurator nonce (wstETH = nonce, jitoSOL =
// nonce + 3; ATOKEN_NONCE overrides). dispatchAsAaveManager swallows inner EVM failures, so the
// dry-run must confirm ReserveInitialized / config / EModeAssetCategoryChanged events, not just
// BatchCompleted.
//
import {
  getApi,
  location,
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import {
  ConfigNames,
  getReserveAddresses,
  getTreasuryAddress,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import {
  configureReservesByHelper,
  initReservesByHelper,
} from "../../helpers/init-helpers";
import { ORACLE_ID, USD_ORACLE_ADAPTER_ID } from "../../helpers/deploy-ids";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getPoolAddressesProvider,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
} from "../../helpers";
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
const JITOSOL = 40;
const PRIME = 43;
const EURC = 44;
const APYUSD = 46;
const HOLLAR = 222;
const SOL = 1000752;
const TBTC = 1000765;
const WSTETH = 1000809;
const HYPE = 1001355;
const SPY = 1001356;
const ZEC = 1001357;
const NEAR = 1001358;
const aWSTETH = 1014;
const aJITOSOL = 1015;

// aTokens, GIGA tokens and stableswap shares the routes pass through
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
const MRL_POOL = 105;
const WETH_POOL = 104;
// HOLLAR-paired shares listed as collateral: H-pools, 2-Pool-PRIME/apyUSD/HEURC/BIL, 3-Pool-MRL
const HOLLAR_POOLS = [110, 111, 112, 113, PRIME_POOL, APYUSD_POOL, HEURC_POOL, 10055, MRL_POOL];
// reserves reachable with one Omnipool hop from GETH / GSOL
const OMNIPOOL_RESERVES = [TBTC, HOLLAR, PAXG, HYPE, SPY, ZEC, NEAR];
// no route possible: WBTC (frozen, no venue), SIGIL (no venue), jsHOLLAR (no router venue)

const WSTETH_ED = "3244646333550"; // awstETH ED = wstETH ED
const JITOSOL_ED = "2651"; // ajitoSOL ED = jitoSOL ED
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// new asset -> its GIGA token (an Omnipool asset)
const WSTETH_TO_GETH = [ss(GETH_POOL, WSTETH, GETH_POOL), aave(GETH_POOL, GETH)];
const JITOSOL_TO_GSOL = [ss(GSOL_POOL, JITOSOL, GSOL_POOL), aave(GSOL_POOL, GSOL)];
// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(WETH_POOL, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

// legs from an Omnipool asset `g` to every reserve the router reaches through the Omnipool
const fromOmnipool = (g) => ({
  [USDC]: [omni(g, HOLLAR), ss(110, HOLLAR, AUSDC), aave(AUSDC, USDC)],
  [USDT]: [omni(g, HOLLAR), ss(111, HOLLAR, AUSDT), aave(AUSDT, USDT)],
  [DOT]: [omni(g, ADOT), aave(ADOT, DOT)],
  [VDOT]: [omni(g, ADOT), ss(GDOT_POOL, ADOT, VDOT)],
  [GDOT_POOL]: [omni(g, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)],
  [THREE_POOL]: [omni(g, HOLLAR), ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)],
  [PRIME]: [omni(g, HOLLAR), ss(PRIME_POOL, HOLLAR, PRIME)],
  [EURC]: [omni(g, HOLLAR), ss(HEURC_POOL, HOLLAR, AEURC), aave(AEURC, EURC)],
  [APYUSD]: [omni(g, HOLLAR), ss(APYUSD_POOL, HOLLAR, APYUSD)],
  [USDC_WH]: [omni(g, HOLLAR), ss(MRL_POOL, HOLLAR, USDC_WH)],
  [USDT_WH]: [omni(g, HOLLAR), ss(MRL_POOL, HOLLAR, USDT_WH)],
  ...Object.fromEntries(HOLLAR_POOLS.map((p) => [p, [omni(g, HOLLAR), ss(p, HOLLAR, p)]])),
  ...Object.fromEntries(OMNIPOOL_RESERVES.map((r) => [r, [omni(g, r)]])),
});

task(`lst-mm`, `wstETH + jitoSOL money-market listing (ETH / SOL e-modes) + aToken registration + routes + ICE routing`).setAction(
  async function (_, hre) {
    const { utils, BigNumber } = hre.ethers;
    const network = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[network];
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const api = await getApi();
    const hydrationTx = api.tx;
    const poolAddressesProvider = await getPoolAddressesProvider();

    const reserveAddresses = await getReserveAddresses(config, network);
    const assets = { WSTETH: reserveAddresses.WSTETH, JITOSOL: reserveAddresses.JITOSOL };

    // oracle sources: USDOracleAdapter per asset (env override, else the deployment artifact)
    const sourceOf = async (symbol) => {
      const env = process.env[`${symbol}_ORACLE`];
      if (env) return env;
      const artifact = await hre.deployments.getOrNull(`${symbol}-${USD_ORACLE_ADAPTER_ID}`);
      if (!artifact) throw new Error(`no ${symbol}_ORACLE and no ${symbol}-${USD_ORACLE_ADAPTER_ID} deployment: deploy the adapter first`);
      return artifact.address;
    };
    const sources = { WSTETH: await sourceOf("WSTETH"), JITOSOL: await sourceOf("JITOSOL") };
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const prices = { WSTETH: await feed(sources.WSTETH).latestAnswer(), JITOSOL: await feed(sources.JITOSOL).latestAnswer() };
    console.log(`oracle sources: wstETH ${sources.WSTETH} ($${prices.WSTETH / 1e8}), jitoSOL ${sources.JITOSOL} ($${prices.JITOSOL / 1e8})`);

    const deployer = await poolAddressesProvider.getPoolConfigurator();
    const liveNonce = await hre.ethers.provider.getTransactionCount(deployer);
    const nonce = process.env.ATOKEN_NONCE ? Number(process.env.ATOKEN_NONCE) : liveNonce;
    const aTokens = {
      WSTETH: utils.getContractAddress({ from: deployer, nonce }),
      JITOSOL: utils.getContractAddress({ from: deployer, nonce: nonce + 3 }),
    };
    console.log(`PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""} -> awstETH ${aTokens.WSTETH}, ajitoSOL ${aTokens.JITOSOL}`);

    // 1. aave manager: oracle sources, init, configure, protocol fee, e-mode membership
    const oracleArtifact = await hre.deployments.get(ORACLE_ID);
    const oracle = await hre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
    const { addTransaction } = await import("../../helpers/transaction-batch");
    addTransaction(
      await oracle.populateTransaction.setAssetSources(
        [assets.WSTETH, assets.JITOSOL],
        [sources.WSTETH, sources.JITOSOL]
      )
    );
    const treasuryAddress = await getTreasuryAddress(config, network);
    const incentivesController = await hre.deployments.get("IncentivesProxy");
    await initReservesByHelper(
      config.ReservesConfig,
      assets,
      config.ATokenNamePrefix,
      config.StableDebtTokenNamePrefix,
      config.VariableDebtTokenNamePrefix,
      config.SymbolPrefix,
      admin,
      treasuryAddress,
      incentivesController.address,
      true
    );
    await configureReservesByHelper(config.ReservesConfig, assets, true);
    await hre.run("setup-liquidation-protocol-fee", { batch: true, only: "WSTETH,JITOSOL" });
    // e-mode categories: review-e-mode diffs config vs chain and batches setEModeCategory when they differ
    for (const name of ["DotEMode", "EthEMode", "SolEMode"]) await hre.run("review-e-mode", { name, fix: true, batch: true });
    const configurator = await getPoolConfiguratorProxy();
    for (const [symbol, eMode] of [["WSTETH", config.EModes.EthEMode], ["JITOSOL", config.EModes.SolEMode]]) {
      if (!eMode.assets.includes(symbol)) throw new Error(`${symbol} missing from e-mode ${eMode.label} config`);
      addTransaction(
        await configurator.populateTransaction.setAssetEModeCategory(assets[symbol], eMode.id, { gasLimit: 1_000_000 })
      );
      console.log(`${symbol} -> e-mode ${eMode.id} (${eMode.label})`);
    }
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. aToken registry entries + fee currencies.
    // Fee price = aToken raw units per HDX raw unit as FixedU128 (1e18): hdxUsd * 10^(dec-12) / assetUsd.
    // It is only the fallback for when the route oracle has no price.
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const feePrice = (assetUsd, dec) =>
      dec >= 12
        ? hdxUsd.mul(BigNumber.from(10).pow(dec - 12 + 18)).div(assetUsd).toString()
        : hdxUsd.mul(BigNumber.from(10).pow(18)).div(assetUsd.mul(BigNumber.from(10).pow(12 - dec))).toString();
    const register = (id, symbol, ed, decimals, aToken) =>
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id,
          name: symbol,
          assetType: "Erc20",
          existentialDeposit: ed,
          symbol,
          decimals,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      );
    const rootTxs = [
      register(aWSTETH, "awstETH", WSTETH_ED, 18, aTokens.WSTETH),
      register(aJITOSOL, "ajitoSOL", JITOSOL_ED, 9, aTokens.JITOSOL),
      hydrationTx.multiTransactionPayment.addCurrency(aWSTETH, feePrice(prices.WSTETH, 18)),
      hydrationTx.multiTransactionPayment.addCurrency(aJITOSOL, feePrice(prices.JITOSOL, 9)),
    ];
    console.log(`HDX/USD ${hdxUsd} -> fee prices awstETH ${feePrice(prices.WSTETH, 18)}, ajitoSOL ${feePrice(prices.JITOSOL, 9)}`);

    // 3. routes
    const viaGETH = fromOmnipool(GETH);
    const viaGSOL = fromOmnipool(GSOL);
    const routes = [
      // fee-currency pricing of the aTokens (HDX fallback, EVM fee pricing)
      [HDX, aWSTETH, [omni(HDX, GETH), aave(GETH, GETH_POOL), ss(GETH_POOL, GETH_POOL, WSTETH), aave(WSTETH, aWSTETH)]],
      [WETH, aWSTETH, [ss(WETH_POOL, WETH, AETH), ss(GETH_POOL, AETH, WSTETH), aave(WSTETH, aWSTETH)]],
      [HDX, aJITOSOL, [omni(HDX, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, JITOSOL), aave(JITOSOL, aJITOSOL)]],
      [WETH, aJITOSOL, [...WETH_TO_GETH, omni(GETH, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, JITOSOL), aave(JITOSOL, aJITOSOL)]],
      // wstETH vs the ETH side of its own pool (no Omnipool leg)
      [WSTETH, ETH, [ss(GETH_POOL, WSTETH, AETH), aave(AETH, ETH)]],
      [WSTETH, GETH_POOL, [ss(GETH_POOL, WSTETH, GETH_POOL)]],
      // wstETH vs the SOL side
      [WSTETH, SOL, [...WSTETH_TO_GETH, omni(GETH, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
      [WSTETH, GSOL_POOL, [...WSTETH_TO_GETH, omni(GETH, GSOL), aave(GSOL, GSOL_POOL)]],
      [WSTETH, JITOSOL, [...WSTETH_TO_GETH, omni(GETH, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, JITOSOL)]],
      // wstETH vs everything reached through the Omnipool
      ...Object.entries(viaGETH).map(([r, legs]) => [WSTETH, Number(r), [...WSTETH_TO_GETH, ...legs]]),
      // jitoSOL vs the SOL side of its own pool (no Omnipool leg); (40, SOL) is already stored on chain
      [JITOSOL, GSOL_POOL, [ss(GSOL_POOL, JITOSOL, GSOL_POOL)]],
      // missing today: 2-Pool-GSOL share collateral -> SOL debt (ETH twin (34, 4200) exists)
      [GSOL_POOL, SOL, [ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
      // jitoSOL vs the ETH side
      [JITOSOL, ETH, [...JITOSOL_TO_GSOL, omni(GSOL, GETH), aave(GETH, GETH_POOL), ss(GETH_POOL, GETH_POOL, AETH), aave(AETH, ETH)]],
      [JITOSOL, GETH_POOL, [...JITOSOL_TO_GSOL, omni(GSOL, GETH), aave(GETH, GETH_POOL)]],
      // jitoSOL vs everything reached through the Omnipool
      ...Object.entries(viaGSOL).map(([r, legs]) => [JITOSOL, Number(r), [...JITOSOL_TO_GSOL, ...legs]]),
    ];
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }
    console.log(`${routes.length} routes`);

    // 4. ICE solver routing: opt both Aave wraps in
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [WSTETH, aWSTETH] }, "Included"));
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [JITOSOL, aJITOSOL] }, "Included"));

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
