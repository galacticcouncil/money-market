import { task } from "hardhat/config";
import { BigNumber, constants } from "ethers";

task(
  `deploy-checked-oracle`,
  `Deploys a CheckedOracle: a ManagedOracle that rejects pushed prices more than <maxDiffBps> away from <check>`
)
  .addParam("name", "Asset name -- used for the deployment artifact (e.g. APYUSD)")
  .addParam("description", "Feed description (e.g. APYUSD/USD)")
  .addParam("owner", "Owner address (governance) -- configures the check and can push unchecked")
  .addParam("price", "Initial price, 8 decimals (not checked against the check feed)")
  .addParam("check", "Check feed address (Hydration EMA oracle precompile)")
  .addParam("maxDiffBps", "Max allowed deviation from the check feed, in bps (0..10000)")
  .addOptionalParam("pusher", "Address allowed to push checked prices (default: none)")
  // "version" is a reserved hardhat param name
  .addOptionalParam("feedVersion", "Feed version (default: 1)")
  .setAction(
    async (
      {
        name,
        description,
        owner,
        price,
        check,
        maxDiffBps,
        pusher,
        feedVersion,
      }: {
        name: string;
        description: string;
        owner: string;
        price: string;
        check: string;
        maxDiffBps: string;
        pusher?: string;
        feedVersion?: string;
      },
      hre
    ) => {
      if (!hre.network.config.chainId) {
        throw new Error("INVALID_CHAIN_ID");
      }

      const bps = parseInt(maxDiffBps, 10);
      if (!Number.isInteger(bps) || bps < 0 || bps > 10_000) {
        throw new Error(`maxDiffBps must be an integer in [0, 10000], got ${maxDiffBps}`);
      }

      const initialPrice = BigNumber.from(price);
      if (initialPrice.lte(0)) {
        throw new Error(`price must be positive, got ${price}`);
      }

      const pusherAddress = pusher ?? constants.AddressZero;
      const feedVersionNum = feedVersion ? parseInt(feedVersion, 10) : 1;

      const { deployer } = await hre.getNamedAccounts();
      const artifact = await hre.deployments.deploy(`${name}-CheckedOracle`, {
        from: deployer,
        contract: "CheckedOracle",
        args: [
          description,
          feedVersionNum,
          owner,
          initialPrice,
          check,
          bps,
          pusherAddress,
        ],
        log: true,
      });

      console.log(`CheckedOracle(${name}) deployed at: ${artifact.address}`);
      console.log(`  description: ${description}`);
      console.log(`  owner:       ${owner}`);
      console.log(`  pusher:      ${pusherAddress}`);
      console.log(`  price:       ${initialPrice.toString()}`);
      console.log(`  check:       ${check}`);
      console.log(`  maxDiffBps:  ${bps}`);

      // sanity: what the freshly deployed oracle thinks of its own price
      const oracle = await hre.ethers.getContractAt(
        "CheckedOracle",
        artifact.address
      );
      const [ok, checkPrice] = await oracle.checkPrice();
      if (!ok) {
        console.log(`  check feed:  UNAVAILABLE -- setPrice is blocked until it recovers`);
      } else {
        const [accepted, deviationBps] = await oracle.previewSetPrice(initialPrice);
        console.log(`  check price: ${checkPrice.toString()}`);
        console.log(
          `  deployed price is ${deviationBps.toString()} bps away -- ${
            accepted ? "inside" : "OUTSIDE"
          } the band`
        );
      }
    }
  );
