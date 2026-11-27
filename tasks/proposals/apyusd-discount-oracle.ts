// @ts-nocheck
//
// apyUSD: move the money-market price source and the 2-Pool-apyUSD (146) peg source
// from the apyUSD CheckedOracle (0x80fa…2caf, ref 412) to the apyUSD
// DiscountedCheckedOracle (0x69E3…a0BD, money-market#91, deployed 2026-11-05).
//
// The CheckedOracle has rejected every push since it went live: the vault's fair
// value sits >100 bps above the apyUSD/HOLLAR day-EMA, so the gate holds it at the
// launch price 1.3672318. The discounted oracle stores fair value × 0.985 and gates
// the discounted value against the same EMA, which lands inside the band, so it
// updates with every Wormhole push (pusher = the dedicated receiver 0x75f0…b432).
//
// Both consumers move in one Root-track batch, as in ref 412:
//   1. dispatchAsAaveManager(AaveOracle.setAssetSources([apyUSD], [discounted]))
//      (AaveManagerOrigin = Root | EconomicParameters)
//   2. stableswap.updateAssetPegSource(146, 46, MMOracle(discounted))
//      (stableswap AuthorityOrigin = Root | OmnipoolAdmin)
// The money-market price steps to the oracle's current answer at enactment; the
// pool peg walks there at the pool's maxPegUpdate (40 perbill/block), which this
// proposal does not change.
//
// Run: MARKET_NAME=Hydration HARDHAT_NETWORK=hydration FORK=hydration \
//        npx hardhat apyusd-discount-oracle
// The task reads the source config from markets/hydration (APYUSD aggregator) and
// refuses to build if it differs from the address pinned below, or if the oracle
// on-chain is not a DiscountedCheckedOracle owned by the aave manager.
//
import {
  getApi,
  generateProposalV2,
  aaveManagerCall,
} from "../../helpers/hydration-proposal.js";
import {
  ConfigNames,
  getChainlinkOracles,
  loadPoolConfig,
} from "../../helpers/market-config-helpers";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import { getBatch, clearBatch } from "../../helpers/transaction-batch";
import { FORK, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

const APYUSD = 46;
const APYUSD_POOL = 146;
const APYUSD_DISCOUNTED_ORACLE = "0x69E3409b0A1EEe647971650f594Bce5e8529a0BD";
const APYUSD_CHECKED_ORACLE = "0x80FaaC4Da72FCcABDa5B276D9A931252D6242Caf";
const EVM_DEFAULT_GAS = 1_000_000;

const ORACLE_ABI = [
  "function latestAnswer() view returns (int256)",
  "function owner() view returns (address)",
  "function pusher() view returns (address)",
  "function coefficient() view returns (uint256)",
  "function maxDiffBps() view returns (uint256)",
  "function checkPrice() view returns (bool ok, int256 price)",
];

task(
  `apyusd-discount-oracle`,
  `apyUSD: money-market price source + pool 146 peg source -> DiscountedCheckedOracle`
).setAction(async function (_, hre) {
  const network = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[network];
  const config = await loadPoolConfig(MARKET_NAME as ConfigNames);
  const api = await getApi();

  const configured = (await getChainlinkOracles(config, network)).APYUSD;
  if (configured.toLowerCase() !== APYUSD_DISCOUNTED_ORACLE.toLowerCase()) {
    throw new Error(
      `markets/hydration APYUSD aggregator ${configured} != ${APYUSD_DISCOUNTED_ORACLE}`
    );
  }

  const oracle = new hre.ethers.Contract(
    APYUSD_DISCOUNTED_ORACLE,
    ORACLE_ABI,
    hre.ethers.provider
  );
  const old = new hre.ethers.Contract(
    APYUSD_CHECKED_ORACLE,
    ORACLE_ABI,
    hre.ethers.provider
  );
  const [answer, owner, pusher, coefficient, band, [checkOk, check], oldAnswer] =
    await Promise.all([
      oracle.latestAnswer(),
      oracle.owner(),
      oracle.pusher(),
      oracle.coefficient(),
      oracle.maxDiffBps(),
      oracle.checkPrice(),
      old.latestAnswer(),
    ]);
  if (owner.toLowerCase() !== admin.toLowerCase()) {
    throw new Error(`oracle owner ${owner} != aave manager ${admin}`);
  }
  const fmt8 = (v) => (Number(v.toString()) / 1e8).toFixed(8);
  console.log(`DiscountedCheckedOracle ${APYUSD_DISCOUNTED_ORACLE}`);
  console.log(
    `  answer ${fmt8(answer)} (coefficient ${fmt8(coefficient)}, band ${band} bps, check feed ${checkOk ? fmt8(check) : "UNAVAILABLE"}) pusher ${pusher}`
  );
  console.log(`CheckedOracle ${APYUSD_CHECKED_ORACLE} answer ${fmt8(oldAnswer)}`);
  console.log(
    `  money-market apyUSD price steps ${fmt8(oldAnswer)} -> ${fmt8(answer)} (${((Number(answer) / Number(oldAnswer) - 1) * 100).toFixed(2)}%) at enactment`
  );

  // 1. AaveOracle.setAssetSources([apyUSD], [discounted]) as the aave manager
  await hre.run("set-reserve-oracle", { symbol: "APYUSD", batch: true });
  const txs = [];
  for (const el of getBatch()) {
    el.from = admin;
    el.gasLimit = el.gasLimit ?? EVM_DEFAULT_GAS;
    txs.push(await aaveManagerCall(el));
  }
  clearBatch();

  // 2. pool 146 peg source for apyUSD -> MMOracle(discounted)
  const pegs = await api.query.stableswap.poolPegs(APYUSD_POOL);
  console.log(`pool ${APYUSD_POOL} pegs now: ${JSON.stringify(pegs.toHuman())}`);
  txs.push(
    api.tx.stableswap.updateAssetPegSource(APYUSD_POOL, APYUSD, {
      MMOracle: APYUSD_DISCOUNTED_ORACLE,
    })
  );

  const preimage = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimage:");
  console.log(preimage.toHex());
  decoder.printTree(decoder.transformCall(preimage.toHuman()));
  console.log("hash:", preimage.hash.toHex());
  console.log("length:", preimage.encodedLength);
});
