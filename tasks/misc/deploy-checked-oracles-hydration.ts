import { task } from "hardhat/config";
import { BigNumber, constants } from "ethers";
import { POOL_ADMIN } from "../../helpers/constants";

/**
 * Deploys the production CheckedOracles for Hydration in one go, with
 * every constructor argument pinned in this file so the deployment is
 * reviewable as a diff rather than as a shell history.
 *
 * Per asset: pushed price (wormhole-direct receiver) is checked at write time
 * against the pool day-EMA precompile; pushes more than `maxDiffBps` away are
 * rejected and the last accepted value stands.
 *
 * Initial prices are the values the eventual consumers see today, so the later
 * source swap is a no-op at the moment of switching:
 *   apyUSD / PRIME  -> current AaveOracle answers (fixed / managed oracles)
 *   wstETH / jitoSOL -> current peg-source oracles of stablepools 4200 / 90001
 *
 * Check feeds are the routed day-EMA (period 0x04) precompile addresses:
 *   0x000001 | 04 | 8 zero bytes (routed) | assetA | assetB
 */
const WH_RECEIVER_ETHEREUM = "0x6913770466fed4dbc24337cd7f1ae92af4321083";
const WH_RECEIVER_SOLANA = "0x582e2fac5af62dc024396b5e7f549c72273a69c3";
const WH_RECEIVER_ROBINHOOD = "0x3b6e3469d8e64e306f235838e0fdf7b4d60a39ce";

type CheckedOracleSpec = {
  name: string;
  description: string;
  price: string; // 8 decimals
  check?: string; // day-EMA precompile; omitted = unchecked
  maxDiffBps: number;
  pusher: string;
};

export const CHECKED_ORACLES: CheckedOracleSpec[] = [
  {
    name: "APYUSD",
    description: "apyUSD/USD",
    price: "136723180",
    check: "0x000001040000000000000000000000de0000002e", // HOLLAR(222) -> apyUSD(46)
    maxDiffBps: 100,
    pusher: WH_RECEIVER_ETHEREUM,
  },
  {
    name: "PRIME",
    description: "PRIME/USD",
    price: "105050000",
    check: "0x000001040000000000000000000000de0000002b", // HOLLAR(222) -> PRIME(43)
    maxDiffBps: 100,
    pusher: WH_RECEIVER_SOLANA,
  },
  {
    name: "WSTETH",
    description: "wstETH/stETH",
    price: "124030000",
    check: "0x00000104000000000000000000000014000f4569", // WETH(20) -> wstETH(1000809)
    maxDiffBps: 50,
    pusher: WH_RECEIVER_ETHEREUM,
  },
  {
    name: "JITOSOL",
    description: "jitoSOL/SOL",
    price: "129240000",
    check: "0x000001040000000000000000000f453000000028", // SOL(1000752) -> jitoSOL(40)
    maxDiffBps: 75,
    pusher: WH_RECEIVER_SOLANA,
  },
  {
    name: "SPY",
    description: "SPY/USD",
    price: "78008287704",
    // No check: SPY is in no Hydration pool, so no day-EMA exists for it yet.
    // Once HOLLAR/SPY trades: 0x000001040000000000000000000000de000f488c
    maxDiffBps: 100,
    pusher: WH_RECEIVER_ROBINHOOD,
  },
];

const CHECKED_ORACLE_ABI = [
  "function latestAnswer() view returns (int256)",
  "function owner() view returns (address)",
  "function pusher() view returns (address)",
  "function checkOracle() view returns (address)",
  "function checkDecimals() view returns (uint8)",
  "function maxDiffBps() view returns (uint256)",
  "function checkPrice() view returns (bool ok, int256 price)",
];

const fmt8 = (v: BigNumber) => (Number(v.toString()) / 1e8).toFixed(8);

task(
  `deploy-checked-oracles-hydration`,
  `Deploys the production CheckedOracles (apyUSD, PRIME, wstETH, jitoSOL, SPY) with pinned params and runs post-deploy sanity reads`
)
  .addOptionalParam(
    "only",
    "Comma-separated subset of names to deploy (APYUSD,PRIME,WSTETH,JITOSOL,SPY)"
  )
  .setAction(async ({ only }: { only?: string }, hre) => {
    const network = hre.network.name;
    const owner = POOL_ADMIN[network];
    if (!owner) throw new Error(`No POOL_ADMIN configured for network ${network}`);

    const wanted = only
      ? new Set(only.split(",").map((s) => s.trim().toUpperCase()))
      : undefined;
    const specs = CHECKED_ORACLES.filter((s) => !wanted || wanted.has(s.name));
    if (specs.length === 0) throw new Error(`--only matched nothing: ${only}`);

    console.log(`\nnetwork ${network} | owner (POOL_ADMIN) ${owner}\n`);

    for (const s of specs) {
      await hre.run("deploy-checked-oracle", {
        name: s.name,
        description: s.description,
        owner,
        price: s.price,
        ...(s.check ? { check: s.check } : {}), // omitted = unchecked
        maxDiffBps: String(s.maxDiffBps),
        pusher: s.pusher,
      });
    }

    console.log(`\n--- post-deploy sanity ---`);
    for (const s of specs) {
      const dep = await hre.deployments.get(`${s.name}-CheckedOracle`);
      const oracle = await hre.ethers.getContractAt(CHECKED_ORACLE_ABI, dep.address);

      const [answer, ownerOnChain, pusher, checkOracle, checkDecimals, band] =
        await Promise.all([
          oracle.latestAnswer(),
          oracle.owner(),
          oracle.pusher(),
          oracle.checkOracle(),
          oracle.checkDecimals(),
          oracle.maxDiffBps(),
        ]);
      const [checkOk, checkPrice] = await oracle.checkPrice();

      const bad: string[] = [];
      if (!answer.eq(BigNumber.from(s.price))) bad.push("initial price mismatch");
      if (ownerOnChain.toLowerCase() !== owner.toLowerCase()) bad.push("owner mismatch");
      if (pusher.toLowerCase() !== s.pusher.toLowerCase()) bad.push("pusher mismatch");
      if (checkOracle.toLowerCase() !== (s.check ?? constants.AddressZero).toLowerCase())
        bad.push("check feed mismatch");
      if (checkDecimals !== 8) bad.push(`check decimals ${checkDecimals} != 8`);
      if (!band.eq(s.maxDiffBps)) bad.push("band mismatch");

      console.log(`\n${s.name}-CheckedOracle ${dep.address}`);
      console.log(`  reports ${fmt8(answer)} | band ${band.toString()} bps | pusher ${pusher}`);
      console.log(
        s.check
          ? `  check feed ${checkOracle} -> ${checkOk ? fmt8(checkPrice) : "UNAVAILABLE (fail-closed: pushes rejected until it answers)"}`
          : `  check feed none -- UNCHECKED: every push stored until setCheckOracle`
      );
      console.log(bad.length ? `  !! ${bad.join("; ")}` : `  config OK`);
    }
  });
