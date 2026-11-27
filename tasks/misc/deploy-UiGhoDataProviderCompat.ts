import { task } from "hardhat/config";

const HYDRATION_CHAIN_ID = 222222;
const MAIN_POOL = "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38";
const HOLLAR = "0x531a654d1696ED52e7275A8cede955E82620f99a";

task(
  "deploy-UiGhoDataProviderCompat",
  "Deploys the HOLLAR UI provider compatible with non-legacy discount strategies"
)
  .addOptionalParam(
    "pool",
    "Aave Pool containing the HOLLAR reserve",
    MAIN_POOL
  )
  .addOptionalParam("ghoToken", "HOLLAR/GHO token address", HOLLAR)
  .setAction(
    async ({ pool, ghoToken }: { pool: string; ghoToken: string }, hre) => {
      if (hre.network.config.chainId !== HYDRATION_CHAIN_ID) {
        throw new Error(
          `UiGhoDataProviderCompat is a Hydration deployment (chain ${HYDRATION_CHAIN_ID}); got ${hre.network.config.chainId}`
        );
      }
      if (
        hre.network.name !== "hardhat" &&
        !process.env.PRIV_KEY &&
        !process.env.MNEMONIC
      ) {
        throw new Error(
          "Set PRIV_KEY or MNEMONIC explicitly for a live deployment"
        );
      }

      const [poolCode, tokenCode] = await Promise.all([
        hre.ethers.provider.getCode(pool),
        hre.ethers.provider.getCode(ghoToken),
      ]);
      if (poolCode === "0x") throw new Error(`No Pool code at ${pool}`);
      if (tokenCode === "0x") throw new Error(`No HOLLAR code at ${ghoToken}`);

      const { deployer } = await hre.getNamedAccounts();
      const deployment = await hre.deployments.deploy(
        "UiGhoDataProviderCompat",
        {
          from: deployer,
          contract: "UiGhoDataProviderCompat",
          args: [pool, ghoToken],
          log: true,
        }
      );

      const provider = await hre.ethers.getContractAt(
        "UiGhoDataProviderCompat",
        deployment.address
      );
      const reserve = await provider.getGhoReserveData();
      if ((await provider.POOL()).toLowerCase() !== pool.toLowerCase()) {
        throw new Error("Deployed provider has the wrong Pool immutable");
      }
      if ((await provider.GHO()).toLowerCase() !== ghoToken.toLowerCase()) {
        throw new Error("Deployed provider has the wrong HOLLAR immutable");
      }

      console.log(`UiGhoDataProviderCompat: ${deployment.address}`);
      console.log(`  pool:              ${pool}`);
      console.log(`  HOLLAR:            ${ghoToken}`);
      console.log(
        `  base borrow rate:  ${reserve.ghoBaseVariableBorrowRate.toString()}`
      );
      console.log(
        `  current index:     ${reserve.ghoCurrentBorrowIndex.toString()}`
      );
      console.log("  getGhoReserveData: OK");
    }
  );
