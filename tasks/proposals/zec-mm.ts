// @ts-nocheck
//
// ZEC money-market listing (Oct 2026, Root track) — the ZEC twin of hype-mm.ts.
//
// ZEC (1001357, 8 decimals) is launched in the Omnipool as a raw token by ref 434.
// This lists it in the main market with the HYPE/SOL parameters (LTV 70 / LT 75 /
// bonus 7%, borrowable, reserve factor 20%, SOL's rate strategy, DIA ZEC/USD feed),
// caps $1M supply / $500k borrow converted at the feed (reservesConfigs.ts `strategyZEC`).
//
// One enactment batch:
//   1. init-reserve ZEC: setAssetSources, initReserves, configureReserves,
//      liquidation protocol fee                                 (aave manager)
//   2. assetRegistry.register aZEC (1011) at the predicted aToken address,
//      multiTransactionPayment.addCurrency                     (root)
//   3. routes HDX/WETH -> aZEC (fee currency pricing), and a liquidation route
//      between ZEC and every reserve outside the Omnipool        (root)
//   4. ice.updateRouting(AaveWrap(ZEC, aZEC), Included) so the ICE solver can
//      route intents through the new wrap (HYPE needed a follow-up TC motion for this)
//   5. router.sellAll ZEC -> aZEC for the treasury's whole free ZEC (dispatchAsTreasury)
//
// The aToken address is predicted from the PoolConfigurator nonce (+3 per reserve
// initialised ahead of this one; ATOKEN_NONCE overrides). The fee-currency fallback
// price is read from the HDX and ZEC feeds at build time. Routes through the
// Omnipool only validate once ZEC is in it, so the live dry-run needs ref 434 enacted.
//
// dispatchAsTreasury and dispatchAsAaveManager swallow inner failures, so the dry-run
// must confirm the ReserveInitialized/config events and the treasury's aZEC balance,
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
const ZEC = 1001357;
const aZEC = 1011;

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

const ZEC_ED = "674"; // aZEC ED = ZEC ED (aPRIME precedent)
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";
const ZEC_FEED = "0xd76f6e296e34ad163439d16731800c3e2c081c6e";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(104, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

task(`zec-mm`, `ZEC money-market listing + aZEC registration + ICE routing + treasury ZEC -> aZEC`).setAction(
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
    console.log(`PoolConfigurator ${deployer} nonce ${liveNonce}${nonce !== liveNonce ? ` (building for ${nonce})` : ""} -> aZEC ${aToken}`);

    // 1. reserve init + config, all from strategyZEC
    await hre.run("init-reserve", { symbol: "ZEC", batch: true });
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. aToken registry entry + fee currency.
    // Fee price = aZEC raw units per HDX raw unit (ZEC 8 dec, HDX 12 dec, so 1e-4 ×
    // 1e18 FixedU128 = 1e14); it is only the fallback for when the route oracle has no price.
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const zecUsd = await feed(ZEC_FEED).latestAnswer();
    const feePrice = hdxUsd.mul(BigNumber.from(10).pow(14)).div(zecUsd).toString();
    console.log(`HDX/USD ${hdxUsd} ZEC/USD ${zecUsd} (8 dec) -> aZEC fee price ${feePrice}`);

    const rootTxs = [
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: aZEC,
          name: "aZEC",
          assetType: "Erc20",
          existentialDeposit: ZEC_ED,
          symbol: "aZEC",
          decimals: 8,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      ),
      hydrationTx.multiTransactionPayment.addCurrency(aZEC, feePrice),
    ];

    // 3. routes
    const routes = [
      // fee-currency pricing of aZEC (HDX fallback, EVM fee pricing)
      [HDX, aZEC, [omni(HDX, ZEC), aave(ZEC, aZEC)]],
      [WETH, aZEC, [...WETH_TO_GETH, omni(GETH, ZEC), aave(ZEC, aZEC)]],
      // liquidations: ZEC collateral vs debt assets outside the Omnipool (HYPE is in it: no route)
      [USDC, ZEC, [aave(USDC, AUSDC), ss(110, AUSDC, HOLLAR), omni(HOLLAR, ZEC)]],
      [USDT, ZEC, [aave(USDT, AUSDT), ss(111, AUSDT, HOLLAR), omni(HOLLAR, ZEC)]],
      [DOT, ZEC, [aave(DOT, ADOT), omni(ADOT, ZEC)]],
      [ETH, ZEC, [aave(ETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH), omni(GETH, ZEC)]],
      [ZEC, VDOT, [omni(ZEC, ADOT), ss(GDOT_POOL, ADOT, VDOT)]],
      [ZEC, PRIME, [omni(ZEC, HOLLAR), ss(PRIME_POOL, HOLLAR, PRIME)]],
      [ZEC, SOL, [omni(ZEC, GSOL), aave(GSOL, GSOL_POOL), ss(GSOL_POOL, GSOL_POOL, ASOL), aave(ASOL, SOL)]],
      [ZEC, EURC, [omni(ZEC, HOLLAR), ss(HEURC_POOL, HOLLAR, AEURC), aave(AEURC, EURC)]],
      [ZEC, APYUSD, [omni(ZEC, HOLLAR), ss(APYUSD_POOL, HOLLAR, APYUSD)]],
      // liquidations: ZEC debt vs share collateral
      [ZEC, GDOT_POOL, [omni(ZEC, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)]],
      [ZEC, GETH_POOL, [omni(ZEC, GETH), aave(GETH, GETH_POOL)]],
      [ZEC, GSOL_POOL, [omni(ZEC, GSOL), aave(GSOL, GSOL_POOL)]],
      [ZEC, THREE_POOL, [omni(ZEC, HOLLAR), ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)]],
      ...HOLLAR_POOLS.map((p) => [ZEC, p, [omni(ZEC, HOLLAR), ss(p, HOLLAR, p)]]),
      // no route: SIGIL (no venue, no supply) and WBTC (frozen; pool 101 has no Omnipool leg)
      // default Omnipool hop covers HOLLAR, PAXG, tBTC, HYPE
    ];
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // 4. ICE solver routing: opt the new Aave wrap in (same shape as the HYPE follow-up)
    rootTxs.push(hydrationTx.ice.updateRouting({ AaveWrap: [ZEC, aZEC] }, "Included"));

    // 5. treasury's whole free ZEC -> aZEC (supply via the router's Aave pool)
    rootTxs.push(
      await dispatchAsTreasury(hydrationTx.router.sellAll(ZEC, aZEC, 0, [aave(ZEC, aZEC)]))
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
