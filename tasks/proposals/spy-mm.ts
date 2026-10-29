// @ts-nocheck
//
// SPY money-market listing (Oct 2026, Root track) — third of the hype-mm / zec-mm series.
//
// SPY (1001356, 18 decimals) is live in the Omnipool as a raw token (launch ref enacted
// 2026-10-28). This lists it in the main market with the HYPE/SPY parameters (LTV 70 /
// LT 75 / bonus 7%, borrowable, reserve factor 20%, SOL's rate strategy), priced by the
// SPY/USD CheckedOracle fed from Robinhood's Chainlink feed over Wormhole, caps $1M
// supply / $500k borrow converted at the feed (reservesConfigs.ts `strategySPY`).
//
// One enactment batch:
//   1. init-reserve SPY: setAssetSources, initReserves, configureReserves,
//      liquidation protocol fee                                 (aave manager)
//   2. assetRegistry.register aSPY (1012) at the predicted aToken address,
//      multiTransactionPayment.addCurrency                     (root)
//   3. routes HDX/WETH -> aSPY (fee currency pricing), and a liquidation route
//      between SPY and every reserve outside the Omnipool, including the
//      Wormhole USDT/USDC reserves that ref 440 adds                (root)
//   4. ice.updateRouting(AaveWrap(SPY, aSPY), Included) so the ICE solver can
//      route intents through the new wrap
//   5. router.sellAll SPY -> aSPY for the treasury's whole free SPY (dispatchAsTreasury)
//
// The aToken address is predicted from the PoolConfigurator nonce (+3 per reserve
// initialised ahead of this one; ATOKEN_NONCE overrides — ref 440 initialises two
// reserves, so pass 94 if it enacts first). The fee-currency fallback price is read
// from the HDX and SPY feeds at build time.
//
// dispatchAsTreasury and dispatchAsAaveManager swallow inner failures, so the dry-run
// must confirm the ReserveInitialized/config events and the treasury's aSPY balance,
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
const SPY = 1001356;
const aSPY = 1012;
// Wormhole USDT/USDC reserves (ref 440), both constituents of 3-Pool-MRL (105)
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

const SPY_ED = "13061480386097"; // aSPY ED = SPY ED (aPRIME precedent)
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";
const SPY_FEED = "0x802893C9CDD5AaC833E52783DF39e572fe8f8538";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(104, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

task(`spy-mm`, `SPY money-market listing + aSPY registration + ICE routing + treasury SPY -> aSPY`).setAction(
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
    console.log(`PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""} -> aSPY ${aToken}`);

    // 1. reserve init + config, all from strategySPY
    await hre.run("init-reserve", { symbol: "SPY", batch: true });
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. aToken registry entry + fee currency.
    // Fee price = aSPY raw units per HDX raw unit (SPY 18 dec, HDX 12 dec, so 1e6 ×
    // 1e18 FixedU128 = 1e24); it is only the fallback for when the route oracle has no price.
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const spyUsd = await feed(SPY_FEED).latestAnswer();
    const feePrice = hdxUsd.mul(BigNumber.from(10).pow(24)).div(spyUsd).toString();
    console.log(`HDX/USD ${hdxUsd} SPY/USD ${spyUsd} (8 dec) -> aSPY fee price ${feePrice}`);

    const rootTxs = [
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: aSPY,
          name: "aSPY",
          assetType: "Erc20",
          existentialDeposit: SPY_ED,
          symbol: "aSPY",
          decimals: 18,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      ),
      hydrationTx.multiTransactionPayment.addCurrency(aSPY, feePrice),
    ];

    // 3. routes
    const routes = [
      // fee-currency pricing of aSPY (HDX fallback, EVM fee pricing)
      [HDX, aSPY, [omni(HDX, SPY), aave(SPY, aSPY)]],
      [WETH, aSPY, [...WETH_TO_GETH, omni(GETH, SPY), aave(SPY, aSPY)]],
      // liquidations: SPY collateral vs debt assets outside the Omnipool (HYPE/SPY are in it: no route)
      [USDC, SPY, [aave(USDC, AUSDC), ss(110, AUSDC, HOLLAR), omni(HOLLAR, SPY)]],
      [USDT, SPY, [aave(USDT, AUSDT), ss(111, AUSDT, HOLLAR), omni(HOLLAR, SPY)]],
      [DOT, SPY, [aave(DOT, ADOT), omni(ADOT, SPY)]],
      [ETH, SPY, [aave(ETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH), omni(GETH, SPY)]],
      [SPY, VDOT, [omni(SPY, ADOT), ss(GDOT_POOL, ADOT, VDOT)]],
      [SPY, PRIME, [omni(SPY, HOLLAR), ss(PRIME_POOL, HOLLAR, PRIME)]],
      [SPY, SOL, [omni(SPY, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
      [SPY, EURC, [omni(SPY, HOLLAR), ss(HEURC_POOL, HOLLAR, AEURC), aave(AEURC, EURC)]],
      [SPY, APYUSD, [omni(SPY, HOLLAR), ss(APYUSD_POOL, HOLLAR, APYUSD)]],
      [SPY, USDC_WH, [omni(SPY, HOLLAR), ss(MRL_POOL, HOLLAR, USDC_WH)]],
      [SPY, USDT_WH, [omni(SPY, HOLLAR), ss(MRL_POOL, HOLLAR, USDT_WH)]],
      // liquidations: SPY debt vs share collateral
      [SPY, GDOT_POOL, [omni(SPY, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)]],
      [SPY, GETH_POOL, [omni(SPY, GETH), aave(GETH, GETH_POOL)]],
      [SPY, GSOL_POOL, [omni(SPY, GSOL), aave(GSOL, GSOL_POOL)]],
      [SPY, THREE_POOL, [omni(SPY, HOLLAR), ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)]],
      ...HOLLAR_POOLS.map((p) => [SPY, p, [omni(SPY, HOLLAR), ss(p, HOLLAR, p)]]),
      // no route: SIGIL (no venue, no supply) and WBTC (frozen; pool 101 has no Omnipool leg)
      // default Omnipool hop covers HOLLAR, PAXG, tBTC, HYPE, SPY
    ];
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // 4. ICE solver routing: opt the new Aave wrap in (same shape as the HYPE follow-up)
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [SPY, aSPY] }, "Included"));

    // 5. treasury's whole free SPY -> aSPY (supply via the router's Aave pool)
    rootTxs.push(
      await dispatchAsTreasury(hydrationTx.router.sellAll(SPY, aSPY, 0, [aave(SPY, aSPY)]))
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
