import { task } from "hardhat/config";

/**
 * Deploys a fair-value USD oracle for one Gamma Hypervisor share token.
 *
 *   HARDHAT_NETWORK=hydration npx hardhat deploy-GammaHypervisorOracleAdapter \
 *     --hypervisor 0xa206D0959813f17c17C87147271C49065438648A \
 *     --feed0 0xFBCa0A6dC5B74C042DF23025D99ef0F1fcAC6702 \
 *     --symbol GAMMA-ADOT-HOLLAR
 *
 * --feed0 / --feed1 are USD feeds (8 dec) for the pool's token0 / token1.
 * Omit --feed1 for a token1 pegged to $1 (HOLLAR), matching how every
 * HOLLAR stablepool share is priced in the market today.
 */
task(
  `deploy-GammaHypervisorOracleAdapter`,
  `Deploys GammaHypervisorOracleAdapter (fair-value LP share oracle) for a Gamma Hypervisor`
)
  .addParam("hypervisor", "Gamma Hypervisor (share token) address")
  .addParam("feed0", "USD feed (8 dec) for the pool's token0")
  .addOptionalParam("feed1", "USD feed (8 dec) for the pool's token1; omit for a $1-pegged token1", "0x0000000000000000000000000000000000000000")
  .addParam("symbol", "Deployment name prefix, e.g. GAMMA-ADOT-HOLLAR")
  .setAction(async ({ hypervisor, feed0, feed1, symbol }, hre) => {
    if (!hre.network.config.chainId) {
      throw new Error("INVALID_CHAIN_ID");
    }
    const description = `${symbol} / USD`;
    console.log(`\n- GammaHypervisorOracleAdapter deployment`);
    console.log(`  hypervisor: ${hypervisor}`);
    console.log(`  feed0:      ${feed0}`);
    console.log(`  feed1:      ${feed1} ${feed1 === "0x0000000000000000000000000000000000000000" ? "(token1 fixed at $1)" : ""}`);

    const { deployer } = await hre.getNamedAccounts();
    const artifact = await hre.deployments.deploy(`${symbol}-GammaHypervisorOracleAdapter`, {
      from: deployer,
      contract: "GammaHypervisorOracleAdapter",
      args: [hypervisor, feed0, feed1, description],
    });
    console.log(`${symbol}-GammaHypervisorOracleAdapter deployed at:`, artifact.address);

    const adapter = await hre.ethers.getContractAt("GammaHypervisorOracleAdapter", artifact.address);
    const fair = await adapter.latestAnswer();
    const spot = await adapter.spotAnswer();
    console.log(`  latestAnswer (fair): ${fair.toString()} (${(Number(fair.toString()) / 1e8).toFixed(6)} USD/share)`);
    console.log(`  spotAnswer         : ${spot.toString()} (${(Number(spot.toString()) / 1e8).toFixed(6)} USD/share)`);
  });
