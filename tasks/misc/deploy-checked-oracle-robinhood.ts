import { task } from "hardhat/config";
import { BigNumber, constants } from "ethers";
import { eRobinhoodNetwork } from "../../helpers/types";

/**
 * Deploys the HDX/USD CheckedOracle on Robinhood Chain (chain id 4663), the
 * price source of the BandHook pools (galacticcouncil/liquidity), in UNCHECKED
 * mode: Robinhood has no independent HDX reference, so `checkOracle` is
 * address(0) and every push from the wormhole-direct receiver is stored. The
 * owner switches a check on later with `setCheckOracle`; the hook keeps reading
 * this address throughout. Decision: galacticcouncil/money-market#59.
 *
 * What is known is pinned here; what only exists once the Robinhood receiver
 * stack and the hook multisig are deployed comes from the environment and is
 * refused when blank:
 *   ROBINHOOD_ORACLE_OWNER    hook owner multisig on Robinhood (same as the hooks)
 *   ROBINHOOD_ORACLE_PUSHER   OracleReceiver on Robinhood (whm repo)
 *   HDX_USD_PRICE             initial price, 8 decimals, the HDX/USD the market
 *                             implies at deploy time (e.g. 0.0123 -> 1230000)
 *
 * maxDiffBps is pinned at 1000 (10%): the band the first real check is
 * expected to use. It does nothing while unchecked.
 */
const SPEC = {
  name: "HDX",
  description: "HDX/USD",
  maxDiffBps: 1000,
};

const CHECKED_ORACLE_ABI = [
  "function latestAnswer() view returns (int256)",
  "function decimals() view returns (uint8)",
  "function owner() view returns (address)",
  "function pusher() view returns (address)",
  "function checkOracle() view returns (address)",
  "function checked() view returns (bool)",
  "function maxDiffBps() view returns (uint256)",
  "function previewSetPrice(int256 price) view returns (bool ok, uint256 deviationBps)",
];

const fmt8 = (v: BigNumber) => (Number(v.toString()) / 1e8).toFixed(8);

const requireEnv = (name: string): string => {
  const v = (process.env[name] || "").trim();
  if (!v) throw new Error(`Missing ${name}`);
  return v;
};

const requireAddress = (name: string): string => {
  const v = requireEnv(name);
  if (!/^0x[0-9a-fA-F]{40}$/.test(v) || v.toLowerCase() === constants.AddressZero) {
    throw new Error(`${name} must be a non-zero address, got ${v}`);
  }
  return v;
};

task(
  `deploy-checked-oracle-robinhood`,
  `Deploys the HDX/USD CheckedOracle on Robinhood Chain in unchecked mode (no check feed exists there yet) and runs post-deploy sanity reads`
).setAction(async (_, hre) => {
  const network = hre.network.name;
  if (network !== eRobinhoodNetwork.robinhood && !process.env.ALLOW_ANY_NETWORK) {
    throw new Error(
      `This task targets --network ${eRobinhoodNetwork.robinhood} (chain 4663); got ${network}. Set ALLOW_ANY_NETWORK=1 for a fork rehearsal.`
    );
  }

  const owner = requireAddress("ROBINHOOD_ORACLE_OWNER");
  const pusher = requireAddress("ROBINHOOD_ORACLE_PUSHER");
  const price = BigNumber.from(requireEnv("HDX_USD_PRICE"));
  if (price.lte(0)) throw new Error("HDX_USD_PRICE must be positive (8 decimals)");
  // HDX has never traded above $1 or below $0.001; anything outside is a decimals slip.
  if (price.gt(100_000_000) || price.lt(100_000)) {
    throw new Error(`HDX_USD_PRICE ${price.toString()} is outside [0.001, 1] USD -- check the decimals`);
  }

  console.log(`\nnetwork ${network} | owner ${owner} | pusher ${pusher} | initial ${fmt8(price)} USD\n`);

  await hre.run("deploy-checked-oracle", {
    name: SPEC.name,
    description: SPEC.description,
    owner,
    price: price.toString(),
    maxDiffBps: String(SPEC.maxDiffBps),
    pusher,
    // no `check`: unchecked mode
  });

  console.log(`\n--- post-deploy sanity ---`);
  const dep = await hre.deployments.get(`${SPEC.name}-CheckedOracle`);
  const oracle = await hre.ethers.getContractAt(CHECKED_ORACLE_ABI, dep.address);
  const [answer, decimals, ownerOnChain, pusherOnChain, checkOracle, checked, band] =
    await Promise.all([
      oracle.latestAnswer(),
      oracle.decimals(),
      oracle.owner(),
      oracle.pusher(),
      oracle.checkOracle(),
      oracle.checked(),
      oracle.maxDiffBps(),
    ]);
  const [previewOk, previewDev] = await oracle.previewSetPrice(price.mul(2));

  const bad: string[] = [];
  if (!answer.eq(price)) bad.push("initial price mismatch");
  if (decimals !== 8) bad.push(`decimals ${decimals} != 8`);
  if (ownerOnChain.toLowerCase() !== owner.toLowerCase()) bad.push("owner mismatch");
  if (pusherOnChain.toLowerCase() !== pusher.toLowerCase()) bad.push("pusher mismatch");
  if (checkOracle.toLowerCase() !== constants.AddressZero) bad.push("check feed is set; expected none");
  if (checked) bad.push("checked() is true; expected unchecked");
  if (!band.eq(SPEC.maxDiffBps)) bad.push("band mismatch");
  if (!previewOk || !previewDev.isZero()) bad.push("previewSetPrice should accept anything while unchecked");

  console.log(`\n${SPEC.name}-CheckedOracle ${dep.address}`);
  console.log(`  reports ${fmt8(answer)} | UNCHECKED (check feed none) | band ${band.toString()} bps, inert`);
  console.log(`  owner ${ownerOnChain} | pusher ${pusherOnChain}`);
  console.log(bad.length ? `  !! ${bad.join("; ")}` : `  config OK`);
  console.log(`\nnext: whm setOracle migration pointing the Robinhood receiver's HDX assetId at ${dep.address};`);
  console.log(`      liquidity: FEED=${dep.address} in .env.hdx-hollar and FEED_B=${dep.address} in .env.eth-hdx`);
});
