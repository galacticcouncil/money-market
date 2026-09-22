// @ts-nocheck
import {
  aaveManagerCall,
  getApi,
  generateProposalV2,
} from "../../helpers/hydration-proposal.js";
import { task } from "hardhat/config";
import { getBatch } from "../../helpers/transaction-batch";
import {
  FORK,
  getACLManager,
  getPoolAddressesProvider,
  POOL_ADMIN,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";

// Switches the DOT (aDOT) reserve to the rateStrategyDOT275 interest rate
// strategy (0% base, 2.75% slope1, 46.75% slope2, 85% optimal usage; max rate
// unchanged at 49.5%). Deploys a fresh DefaultReserveInterestRateStrategy
// contract and emits the governance proposal that points DOT at it.
//
// Usage: MARKET_NAME=Hydration npx hardhat dot-rate-strategy --network hydration
task(`dot-rate-strategy`, ``).setAction(async function (_, hre) {
  const { poolAdmin } = await hre.getNamedAccounts();
  const signer = await hre.ethers.getSigner(poolAdmin);
  const poolAddressesProvider = await getPoolAddressesProvider();
  const aclManager = (
    await getACLManager(await poolAddressesProvider.getACLManager())
  ).connect(signer);
  console.log("poolAdmin", poolAdmin);
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const isPoolAdmin = await aclManager.isPoolAdmin(admin);
  if (!isPoolAdmin) {
    console.error("not pool admin " + admin);
    return;
  }

  await hre.run("review-rate-strategies", {
    deploy: true,
    fix: true,
    batch: true,
    only: "DOT",
  });

  const txs = await Promise.all(
    getBatch().map((tx) => aaveManagerCall({ ...tx, from: admin }))
  );

  const proposal = await generateProposalV2(txs, false);

  console.log("proposal hash:", proposal.hash.toHex());
  console.log("proposal batch preimage:");
  console.log(proposal.toHex());

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  decoder.printTree(decoder.transformCall(proposal.toHuman()));
});
