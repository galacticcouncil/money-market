// @ts-nocheck
import {
  aaveManagerCall,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import { FORK, POOL_ADMIN } from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Switches the ETH and SOL reserves off the original DOT strategy (rateStrategyDOT: 0 / 7 / 300 @
// 75 %, max 307 %) that both launched on:
//   ETH -> rateStrategyETH  0 % base, 2.2 % slope1,  8.2 % slope2, 85 % optimal (max 10.4 %)
//   SOL -> rateStrategySOL  0 % base, 4.5 % slope1, 49.5 % slope2, 85 % optimal (max 54 %),
//          keeps the SOL borrow rate under the jitoSOL staking APY up to the kink
//
// review-rate-strategies reuses a deployed `ReserveStrategy-<name>` artifact when its on-chain
// params match the config, otherwise it deploys one from `deployer` (needs the whitelisted
// deployer key on mainnet). The proposal is two aave-manager calls:
// PoolConfigurator.setReserveInterestRateStrategyAddress(asset, strategy). Their 100k gas
// default is floored to 1M (the HOLLAR rate change needed 400k; dispatchAsAaveManager swallows
// an out-of-gas, so the ref would pass with the strategy unchanged).
//
// Usage: MARKET_NAME=Hydration HARDHAT_NETWORK=hydration FORK=hydration npx hardhat eth-sol-rate-strategies
task(`eth-sol-rate-strategies`, `ETH -> rateStrategyETH (0 / 2.2 / 8.2 @ 85 %), SOL -> rateStrategySOL (0 / 4.5 / 49.5 @ 85 %)`).setAction(async function (_, hre) {
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];

  await hre.run("review-rate-strategies", { deploy: true, fix: true, batch: true, only: "ETH,SOL" });

  const txs = [];
  for (const el of getBatch()) {
    el.from = admin;
    el.gasLimit = Math.max(Number(el.gasLimit?.toString() ?? 0), 1_000_000);
    txs.push(await aaveManagerCall(el));
  }
  if (!txs.length) throw new Error("review-rate-strategies produced no call: ETH/SOL already on the configured strategies?");

  const proposal = await generateProposalV2(txs, false);
  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  console.log("submit preimage:");
  console.log(proposal.toHex());
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
  console.log("hash:", proposal.hash.toHex());
  console.log("length:", proposal.encodedLength);
});
