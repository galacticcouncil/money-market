// @ts-nocheck
//
// HYPE money-market listing (Oct 2026, Root track).
//
// HYPE (1001355) is live in the Omnipool as a raw token. This lists it in the main
// market with the SOL parameters (LTV 70 / LT 75 / bonus 7%, borrowable, reserve
// factor 20%, SOL's rate strategy, DIA HYPE/USD feed), caps $1M supply / $500k
// borrow converted at the feed (values in reservesConfigs.ts `strategyHYPE`).
//
// One enactment batch:
//   1. init-reserve HYPE: setAssetSources, initReserves, configureReserves,
//      liquidation protocol fee                                 (aave manager)
//   2. assetRegistry.register aHYPE (1010) at the predicted aToken address,
//      multiTransactionPayment.addCurrency                     (root)
//   3. routes HDX/WETH -> aHYPE (fee currency pricing), and the PAXG set of
//      liquidation routes with HYPE in PAXG's place             (root)
//   4. router.sellAll HYPE -> aHYPE for the treasury's whole free HYPE (dispatchAsTreasury)
//
// The aToken address is predicted from the PoolConfigurator nonce: rebuild if any
// reserve is initialised on mainnet before this enacts. The fee-currency fallback
// price is read from the HDX and HYPE feeds at build time.
//
// dispatchAsTreasury and dispatchAsAaveManager swallow inner failures, so the dry-run
// must confirm the ReserveInitialized/config events and the treasury's aHYPE balance,
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
const WETH = 20;
const USDC = 22;
const ETH = 34;
const HOLLAR = 222;
const HYPE = 1001355;
const aHYPE = 1010;

// aDOT, aUSDT, aUSDC, aETH; GETH and its share; GDOT share; 3-Pool; H-pools
const ADOT = 1001;
const AUSDT = 1002;
const AUSDC = 1003;
const AETH = 1007;
const GETH = 420;
const GETH_POOL = 4200;
const GDOT_POOL = 690;
const THREE_POOL = 103;
const H_POOLS = [110, 111, 112, 113];

const HYPE_ED = "114285714285714"; // aHYPE ED = HYPE ED (aPRIME precedent)
const HDX_FEED = "0xea63e594ee00590938E856F2134E6C792bA92d13";
const HYPE_FEED = "0xa2F5bb6B23F7Cdf1a04f50103796D1b305ec17a7";

const EVM_DEFAULT_GAS = 1_000_000;

const trade = (pool, assetIn, assetOut) => ({ pool, assetIn, assetOut });
const omni = (a, b) => trade("Omnipool", a, b);
const aave = (a, b) => trade("Aave", a, b);
const ss = (pool, a, b) => trade({ Stableswap: pool }, a, b);

// WETH -> GETH leg shared by every WETH/ETH route on chain today
const WETH_TO_GETH = [ss(104, WETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH)];

task(`hype-mm`, `HYPE money-market listing + aHYPE registration + treasury HYPE -> aHYPE`).setAction(
  async function (_, hre) {
    const { utils, BigNumber } = hre.ethers;
    const network = FORK ? FORK : hre.network.name;
    const admin = POOL_ADMIN[network];
    const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
    const api = await getApi();
    const hydrationTx = api.tx;
    const poolAddressesProvider = await getPoolAddressesProvider();

    const deployer = await poolAddressesProvider.getPoolConfigurator();
    const nonce = await hre.ethers.provider.getTransactionCount(deployer);
    const aToken = utils.getContractAddress({ from: deployer, nonce });
    console.log(`PoolConfigurator ${deployer} nonce ${nonce} -> aHYPE ${aToken}`);

    // 1. reserve init + config, all from strategyHYPE
    await hre.run("init-reserve", { symbol: "HYPE", batch: true });
    const txs = [];
    for (const el of getBatch()) {
      el.from = admin;
      el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
      txs.push(await aaveManagerCall(el));
    }
    clearBatch();

    // 2. aToken registry entry + fee currency.
    // Fee price = aHYPE raw units per HDX raw unit (HYPE 18 dec, HDX 12 dec); it is
    // only the fallback for when the route oracle has no price.
    const feed = (a) =>
      new hre.ethers.Contract(a, ["function latestAnswer() view returns (int256)"], hre.ethers.provider);
    const hdxUsd = await feed(HDX_FEED).latestAnswer();
    const hypeUsd = await feed(HYPE_FEED).latestAnswer();
    const feePrice = hdxUsd.mul(BigNumber.from(10).pow(24)).div(hypeUsd).toString();
    console.log(`HDX/USD ${hdxUsd} HYPE/USD ${hypeUsd} (8 dec) -> aHYPE fee price ${feePrice}`);

    const rootTxs = [
      hydrationTx.assetRegistry.register(
        ...Object.values({
          id: aHYPE,
          name: "aHYPE",
          assetType: "Erc20",
          existentialDeposit: HYPE_ED,
          symbol: "aHYPE",
          decimals: 18,
          location: location(aToken),
          xcmRateLimit: null,
          isSufficient: true,
        })
      ),
      hydrationTx.multiTransactionPayment.addCurrency(aHYPE, feePrice),
    ];

    // 3. routes
    const routes = [
      // fee-currency pricing of aHYPE (HDX fallback, EVM fee pricing)
      [HDX, aHYPE, [omni(HDX, HYPE), aave(HYPE, aHYPE)]],
      [WETH, aHYPE, [...WETH_TO_GETH, omni(GETH, HYPE), aave(HYPE, aHYPE)]],
      // liquidations: HYPE collateral vs debt assets outside the Omnipool
      [USDC, HYPE, [aave(USDC, AUSDC), ss(110, AUSDC, HOLLAR), omni(HOLLAR, HYPE)]],
      [USDT, HYPE, [aave(USDT, AUSDT), ss(111, AUSDT, HOLLAR), omni(HOLLAR, HYPE)]],
      [DOT, HYPE, [aave(DOT, ADOT), omni(ADOT, HYPE)]],
      [ETH, HYPE, [aave(ETH, AETH), ss(GETH_POOL, AETH, GETH_POOL), aave(GETH_POOL, GETH), omni(GETH, HYPE)]],
      // liquidations: HYPE debt vs share collateral
      [HYPE, GDOT_POOL, [omni(HYPE, ADOT), ss(GDOT_POOL, ADOT, GDOT_POOL)]],
      [HYPE, GETH_POOL, [omni(HYPE, GETH), aave(GETH, GETH_POOL)]],
      [HYPE, THREE_POOL, [omni(HYPE, HOLLAR), ss(111, HOLLAR, AUSDT), ss(THREE_POOL, AUSDT, THREE_POOL)]],
      ...H_POOLS.map((p) => [HYPE, p, [omni(HYPE, HOLLAR), ss(p, HOLLAR, p)]]),
    ];
    for (const [assetIn, assetOut, route] of routes) {
      rootTxs.push(hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
    }

    // 4. treasury's whole free HYPE -> aHYPE (supply via the router's Aave pool)
    rootTxs.push(
      await dispatchAsTreasury(hydrationTx.router.sellAll(HYPE, aHYPE, 0, [aave(HYPE, aHYPE)]))
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
