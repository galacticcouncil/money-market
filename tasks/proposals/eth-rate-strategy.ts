// @ts-nocheck
import {
  aaveManagerCall,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import { FORK, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Switches the ETH reserve to rateStrategyETH (0 % base, 2.2 % slope1, 8.2 % slope2, 85 %
// optimal usage; max variable rate 10.4 %). ETH launched on the original DOT strategy
// (rateStrategyDOT: 0 / 7 / 300 @ 75 %, max 307 %).
//
// review-rate-strategies reuses a deployed `ReserveStrategy-rateStrategyETH` artifact when
// its on-chain params match the config, otherwise it deploys one from `deployer` (needs the
// whitelisted deployer key on mainnet). The proposal is one aave-manager call:
// PoolConfigurator.setReserveInterestRateStrategyAddress(ETH, strategy). Its 100k gas
// default is floored to 1M (the HOLLAR rate change needed 400k; dispatchAsAaveManager
// swallows an out-of-gas, so the ref would pass with the strategy unchanged).
//
// Usage: MARKET_NAME=Hydration HARDHAT_NETWORK=hydration FORK=hydration npx hardhat eth-rate-strategy
task(`eth-rate-strategy`, `ETH reserve -> rateStrategyETH (0 / 2.2 / 8.2 @ 85 %)`).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  await hre.run("review-rate-strategies", { deploy: true, fix: true, batch: true, only: "ETH" });

  const txs = [];
  for (const el of getBatch()) {
    el.from = admin;
    el.gasLimit = Math.max(Number(el.gasLimit?.toString() ?? 0), 1_000_000);
    txs.push(await aaveManagerCall(el));
  }
  if (!txs.length) throw new Error("review-rate-strategies produced no call: ETH already on the configured strategy?");

  const proposal = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("hash:", proposal.hash.toHex());
  console.log("length:", proposal.encodedLength);
});
