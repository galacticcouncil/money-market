// @ts-nocheck
import { location, getApi, aaveManagerCall } from "../../helpers/hydration-proposal.js";
import { MARKET_NAME } from "../../helpers/env";
import { task } from "hardhat/config";
import {
  FORK,
  getPoolConfiguratorProxy,
  POOL_ADMIN,
  EMERGENCY_ADMIN,
  TREASURY_PROXY_ID,
} from "../../helpers";
import ProposalDecoder from "../../helpers/proposal-decoder";
import { parseRoundingPolicies } from "../../juicer-vault/looper/src/rounding-policy";
import { nativeAccount, nativeRoundingPolicy } from "../../scripts/juicer/rounding-native";
import {
  NEXT, LAUNCH, readNextState, nextCalls, reserveCalls, parseBand, envNumber, parseExitHeadroom, executionPolicy, readExecution,
  executionCalls, readDiscount, discountCalls, assumePlanned, bootstrapCalls,
} from "../../scripts/juicer/next-governance";
import { readFileSync, writeFileSync } from "fs";
import { resolve as resolvePath } from "path";
import { stringToU8a, u8aConcat } from "@polkadot/util";

// Fixed $1 oracle (reused for the synthetic — it is pegged $1 by design, like HOLLAR).
const GHO_ORACLE_ADDRESS = "0x6096C9D71F7c06024578a62F4B608a1Bb06834F8";

// ── Juicer synthetic collateral ─────────────────────────────────────────
//   - reserve: LTV 1% / LT 98% / borrowing disabled / non-isolation / $1 oracle
//     → supplied by each CollateralVault to floor its Main position's HF so the
//       principal is un-liquidatable at any collateral price.
//   - LTV must be a SMALL NON-ZERO value: Aave refuses to enable an LTV-0 reserve
//     as collateral (validateUseAsCollateral), which leaves the synth out of
//     totalCollateralBase — HF floor inert + rebalance broken (found live on
//     lark-2). 1% grants negligible borrow power; the vault sizes its borrow off
//     the real-collateral delta and never leans on synth LTV.
//   - LT 98% is CONSUMED LIVE by the vault (`CollateralVault.synthLtBps()` reads
//     bits 16-31 of this reserve's config bitmap). It is not a deploy parameter,
//     so this proposal is the single source of truth for it — and until this
//     batch lands, every `deposit` reverts `SynthReserveNotListed`.
//   - registered as an Erc20 substrate asset so the EVM ERC20 precompile bridges
//     it. MUST be registered BEFORE initReserves (HDCL lesson: the precompile
//     reads decimals from the registry, so initReserves reverts otherwise).
const SYNTH_ASSET_ID = Number(process.env.JUICER_SYNTH_ASSET_ID || 5550);
const SYNTH_ASSET_NAME = process.env.JUICER_SYNTH_NAME || "Juicer Synthetic HOLLAR";
const SYNTH_LT = "9800"; // 98% — read live by the vault
const SYNTH_LTV = "100"; // 1% — must be > 0 (see above), still ~zero borrow power
const SYNTH_BONUS = "10100"; // 1%
const SYNTH_SUPPLY_CAP = "0"; // 0 = unlimited

// ── Router route for the shared loop (HOLLAR ↔ aPRIME) ─────────────────────
// Mainnet ids. `configureDca` takes FIVE args — the sixth (period) went away with
// the pallet-DCA path in c0f9404; the loop now uses pallet_route::sell directly.
const ROUTE_HOLLAR = Number(process.env.JUICER_HOLLAR_ID || 222);
const ROUTE_PRIME = Number(process.env.JUICER_PRIME_ID || 43);
const ROUTE_APRIME = Number(process.env.JUICER_APRIME_ID || 1043);
const ROUTE_POOL = Number(process.env.JUICER_PRIME_POOL_ID || 143);
// Explicit governance decision after measuring complete exit costs. Never
// inherit a testnet's permissive slippage limit in a production proposal.
// 35 bps: PRIME traded ~30 bps over the oracle in pool 143 on 31 oct
const ROUTE_SLIPPAGE_PPM = envNumber("JUICER_SLIPPAGE_PPM", 3500);
// the loop's entries, unwinds and the peg arbitrage all trade pool 143
const ROUTE_POOL_FEE_PPM = envNumber("JUICER_PRIME_POOL_FEE_PPM", NEXT.primePoolFeePpm);

// Per-poke tranche caps (HOLLAR 18dp in, aPRIME 6dp out), one entry or unwind lane trade each.
const DEPLOY_TRANCHE = process.env.JUICER_DEPLOY_TRANCHE || "2500";
const UNWIND_TRANCHE = process.env.JUICER_UNWIND_TRANCHE || "2500";

// Max slippage `compound` tolerates vs the oracle-fair output. Default 0 means
// the floor equals the exact oracle price, so EVERY compound reverts until set.
const COMPOUND_SLIPPAGE_BPS = Number(process.env.JUICER_COMPOUND_SLIPPAGE_BPS || 100);

// ── Router routes for the compound leg (PRIME → each collateral) ───────────
// `Harvester.harvest` calls `vault.compound(prime, cut, minOut, "")` with an
// EMPTY route, so HydraAugustus builds `router.sell(…, [])` and the SUBSTRATE
// router resolves the path from its own `router.routes` storage. When no route
// is stored it falls back to Omnipool — and PRIME (43) is NOT an Omnipool asset,
// it only lives in stableswap pool 143. So without these, every harvest reverts
// and loop carry can never be converted into collateral.
//
// jETH's collateral is GIGAETH (4200, pool 4200's share of aETH 1007 + 1000809),
// jBTC's is tBTC. After PRIME → HOLLAR each route is one already stored on-chain
// (`222 → 4200` and `222 → 1000765`), so every leg is known-executable:
//   PRIME →[ss143]→ HOLLAR →[omnipool]→ 420 →[aave]→ GIGAETH
//   PRIME →[ss143]→ HOLLAR →[omnipool]→ tBTC
// 420 is aGETH, GIGAETH's money-market receipt, which the Omnipool trades.
//
// Override wholesale with JUICER_COMPOUND_ROUTES as JSON:
//   [{"assetOut":4200,"route":[{"pool":{"Stableswap":143},"assetIn":43,"assetOut":222}, …]}]
const COMPOUND_ROUTES: { assetOut: number; route: any[] }[] = process.env
  .JUICER_COMPOUND_ROUTES
  ? JSON.parse(process.env.JUICER_COMPOUND_ROUTES)
  : [
      {
        assetOut: 4200, // GIGAETH
        route: [
          { pool: { Stableswap: ROUTE_POOL }, assetIn: ROUTE_PRIME, assetOut: ROUTE_HOLLAR },
          { pool: { Omnipool: null }, assetIn: ROUTE_HOLLAR, assetOut: 420 },
          { pool: { Aave: null }, assetIn: 420, assetOut: 4200 },
        ],
      },
      {
        assetOut: 1000765, // tBTC
        route: [
          { pool: { Stableswap: ROUTE_POOL }, assetIn: ROUTE_PRIME, assetOut: ROUTE_HOLLAR },
          { pool: { Omnipool: null }, assetIn: ROUTE_HOLLAR, assetOut: 1000765 },
        ],
      },
    ];

// Fresh collateral must also be sellable for Main servicing. Independent
// overrides avoid assuming a customized PRIME route passes through HOLLAR.
// Both defaults reverse routes mainnet already stores; batch 0 skips a stored pair.
const OPERATING_ROUTES: { assetIn: number; assetOut: number; route: any[] }[] = process.env
  .JUICER_OPERATING_ROUTES
  ? JSON.parse(process.env.JUICER_OPERATING_ROUTES)
  : [
      { assetIn: 4200, assetOut: ROUTE_HOLLAR, route: [
        { pool: { Aave: null }, assetIn: 4200, assetOut: 420 },
        { pool: { Omnipool: null }, assetIn: 420, assetOut: ROUTE_HOLLAR },
      ] },
      { assetIn: 1000765, assetOut: ROUTE_HOLLAR, route: [
        { pool: { Omnipool: null }, assetIn: 1000765, assetOut: ROUTE_HOLLAR },
      ] },
    ];

const ROLE = {
  MINTER: "MINTER_ROLE",
  GUARDIAN: "GUARDIAN_ROLE",
  VAULT: "VAULT_ROLE",
};

// the deployer-only deploy's manifest (scripts/juicer/launch-deploy.mjs) as defaults; set variables win
function manifestEnv(m: any): Record<string, string> {
  const a = m.addresses, vaults = m.vaults.filter((x: any) => x.address);
  return {
    JUICER_SYNTH: a.synth, JUICER_SUBLOOP: a.subLoop, JUICER_HARVESTER: a.harvester, JUICER_VAULTS: vaults.map((x: any) => x.address).join(","),
    JUICER_MAIN_DEBTS: vaults.map((x: any) => x.mainDebt).join(","), JUICER_SWAPPER: a.adapter, JUICER_FEE_CONTROLLER: a.fees,
    JUICER_EXECUTION_CONTROLLER: a.controller, JUICER_DISCOUNT_CONTROLLER: a.discount,
    JUICER_GUARDIAN: m.committee, JUICER_ROUNDING_RESERVES: JSON.stringify(vaults.map((x: any) => x.rounding)),
  };
}

const assetIdOf = (address: string) => {
  const n = BigInt(address);
  if (n >> 32n !== 1n) throw new Error(`${address} is not a registered asset's precompile`);
  return Number(n & 0xffffffffn);
};

task(
  `juicer`,
  `Juicer launch — the one referendum after the deployer-only deploy: list, wire, fund, open`
).setAction(async function (_, hre) {
  if (process.env.JUICER_MANIFEST) {
    for (const [k, v] of Object.entries(manifestEnv(JSON.parse(readFileSync(process.env.JUICER_MANIFEST, "utf8"))))) process.env[k] ??= v;
  }
  // 7 days; waiting shares stay invested and earn until their unwind starts
  const withdrawalDelay = envNumber("JUICER_WITHDRAWAL_DELAY", 604800);
  if (!Number.isInteger(withdrawalDelay) || withdrawalDelay < 0 || withdrawalDelay > 0xffffffff) {
    throw new Error("JUICER_WITHDRAWAL_DELAY must be uint32 seconds.");
  }
  if (!Number.isInteger(ROUTE_SLIPPAGE_PPM) || ROUTE_SLIPPAGE_PPM < 0 || ROUTE_SLIPPAGE_PPM >= 1_000_000 || ROUTE_SLIPPAGE_PPM % 100 !== 0) {
    throw new Error("JUICER_SLIPPAGE_PPM must be whole bps (0..999900); it also caps both PRIME lanes.");
  }
  if (!Number.isInteger(ROUTE_POOL_FEE_PPM) || ROUTE_POOL_FEE_PPM < 0 || ROUTE_POOL_FEE_PPM >= 1_000_000) {
    throw new Error("JUICER_PRIME_POOL_FEE_PPM must be a Permill in 0..999999.");
  }
  const { utils, constants } = hre.ethers;
  const networkId = FORK ? FORK : hre.network.name;
  const admin = POOL_ADMIN[networkId];
  const poolConfigurator = await getPoolConfiguratorProxy();
  const api = await getApi();
  const hydrationTx = api.tx;
  const at = (address: string, abi: string[]) => hre.ethers.getContractAt(abi, address);
  const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

  // ── deployed contract addresses ─────────────────────────────────────────
  const resolve = async (env: string, deploymentId: string) => {
    if (process.env[env]) return process.env[env];
    try {
      return (await hre.deployments.get(deploymentId)).address;
    } catch {
      return undefined;
    }
  };
  const need = (name: string, value?: string) => {
    if (!value) throw new Error(`${name} is not set: run scripts/juicer/launch-deploy.mjs and pass JUICER_MANIFEST, or set it`);
    return value;
  };
  const synth = need("JUICER_SYNTH", await resolve("JUICER_SYNTH", "SyntheticToken-Juicer"));
  const subLoop = need("JUICER_SUBLOOP", await resolve("JUICER_SUBLOOP", "SubLoop-Juicer"));
  const harvester = need("JUICER_HARVESTER", await resolve("JUICER_HARVESTER", "Harvester-Juicer"));
  const fees = need("JUICER_FEE_CONTROLLER", await resolve("JUICER_FEE_CONTROLLER", "JuicerFeeController-Juicer"));
  const controller = need("JUICER_EXECUTION_CONTROLLER", await resolve("JUICER_EXECUTION_CONTROLLER", "ExecutionController-Juicer"));
  const discount = need("JUICER_DISCOUNT_CONTROLLER", await resolve("JUICER_DISCOUNT_CONTROLLER", "JuicerDiscount-Juicer"));
  // One or more CollateralVaults, comma-separated, each with its Main ledger (JUICER_MAIN_DEBTS, same order)
  const list = (text?: string) => (text || "").split(",").map((v) => v.trim()).filter(Boolean);
  const vaults = list(process.env.JUICER_VAULTS || process.env.JUICER_VAULT);
  if (!vaults.length) throw new Error("set JUICER_VAULTS (or JUICER_MANIFEST)");
  const ledgers = list(process.env.JUICER_MAIN_DEBTS);
  const swapper = process.env.JUICER_SWAPPER;
  // Technical committee — receives GUARDIAN_ROLE (fast pause) on every contract.
  const guardian = process.env.JUICER_GUARDIAN || EMERGENCY_ADMIN[networkId];
  const keepers = list(process.env.JUICER_KEEPERS);
  if (!keepers.length) throw new Error("set JUICER_KEEPERS: the keepers' KEEPER_ROLE and DEPOSIT_GUARDIAN_ROLE are part of the launch");
  const rounding = parseRoundingPolicies(process.env.JUICER_ROUNDING_RESERVES || "[]", vaults);
  const fundingSource = process.env.JUICER_FUNDING_SOURCE || "treasury";
  if (!["treasury", "admin"].includes(fundingSource)) throw new Error("JUICER_FUNDING_SOURCE is treasury or admin");

  const loopC = await at(subLoop, [
    "function hollar() view returns (address)", "function prime() view returns (address)", "function primeAToken() view returns (address)",
    "function hasRole(bytes32,address) view returns (bool)", "function harvester() view returns (address)",
    "function deployTranche() view returns (uint256)", "function unwindTranche() view returns (uint256)",
    "function hollarAssetId() view returns (uint32)", "function primeAssetId() view returns (uint32)", "function aPrimeAssetId() view returns (uint32)",
    "function primePoolId() view returns (uint32)", "function dcaSlippagePpm() view returns (uint32)",
  ]);
  const [hollar, prime, aPrime] = [await loopC.hollar(), await loopC.prime(), await loopC.primeAToken()];
  const VAULT_ABI = [
    "function asset() view returns (address)", "function mainDebt() view returns (address)", "function roundingReserve() view returns (uint256)",
    "function totalSupply() view returns (uint256)", "function depositsPaused() view returns (bool)", "function feeController() view returns (address)",
    "function compoundSlippageBps() view returns (uint16)", "function withdrawalDelay() view returns (uint32)", "function swapper() view returns (address)",
    "function hasRole(bytes32,address) view returns (bool)", "function name() view returns (string)", "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
  ];
  const rows = [];
  for (const [i, address] of vaults.entries()) {
    const c = await at(address, VAULT_ABI);
    const bound = await c.mainDebt();
    const mainDebt = bound !== constants.AddressZero ? bound : ledgers[i];
    if (!mainDebt) throw new Error(`${address} has no Main ledger yet: set JUICER_MAIN_DEBTS`);
    if (bound !== constants.AddressZero && ledgers[i] && !same(bound, ledgers[i])) throw new Error(`${address} is bound to ${bound}, not ${ledgers[i]}`);
    const ledger = await at(mainDebt, ["function vault() view returns (address)", "function yieldAccounting() view returns (address)"]);
    if (!same(await ledger.vault(), address)) throw new Error(`Invalid Main debt binding: ${address}`);
    const asset = await c.asset();
    rows.push({ address, c, mainDebt, bound, asset, assetId: assetIdOf(asset), key: (await c.symbol()).replace(/^j/, ""), yieldAccounting: await ledger.yieldAccounting() });
  }

  console.log("Juicer launch inputs");
  console.log(`  synthetic  : ${synth} (asset ${SYNTH_ASSET_ID})`);
  console.log(`  subLoop    : ${subLoop}`);
  console.log(`  harvester  : ${harvester}`);
  console.log(`  vaults     : ${rows.map((r) => `${r.address} (Main ${r.mainDebt}, collateral ${r.assetId})`).join(", ")}`);
  console.log(`  swapper    : ${swapper ?? "(not set — the vaults keep theirs)"}`);
  console.log(`  guardian   : ${guardian}`);
  console.log(`  keepers    : ${keepers.join(", ")}`);
  console.log(`  discount   : ${discount}`);
  console.log(`  controller : ${controller}`);
  console.log(`  route      : ${ROUTE_HOLLAR}/${ROUTE_PRIME}/${ROUTE_APRIME} via pool ${ROUTE_POOL} @ ${ROUTE_SLIPPAGE_PPM}ppm`);
  console.log(`  funding    : ${fundingSource}\n`);

  // ── the launch, in order: each step's calls are only what the chain still lacks ──
  type Item = { step: string; label: string; tx?: any; evm?: { to: string; data: string; gas: number } };
  const items: Item[] = [];
  let step = "";
  const sub = (label: string, tx: any) => { console.log(`[${step}] ${label}`); items.push({ step, label, tx }); };
  const evm = (label: string, to: string, data: string, gas = 500_000) => { console.log(`[${step}] ${label}`); items.push({ step, label, evm: { to, data, gas } }); };
  const plan = (calls: { to: string; data: string; label: string; gas?: number }[]) => calls.forEach((c) => evm(c.label, c.to, c.data, c.gas));
  const iface = (sigs: string[]) => new utils.Interface(sigs);
  const accessI = iface(["function grantRole(bytes32,address)"]);
  const loopI = iface(["function registerVault(address)", "function setTranches(uint256,uint256)", "function configureDca(uint32,uint32,uint32,uint32,uint32)", "function setHarvester(address)"]);
  const vaultI = iface(["function fundRoundingReserve(uint256)", "function setWithdrawalDelay(uint32)", "function setCompoundSlippageBps(uint16)",
    "function setSwapper(address)", "function setMainDebt(address)", "function setFeeController(address)"]);
  const tokenI = iface(["function approve(address,uint256) returns (bool)"]);
  const MINTER = utils.id(ROLE.MINTER), GUARDIAN = utils.id(ROLE.GUARDIAN), VAULT = utils.id(ROLE.VAULT);
  const pool = await at((await hre.deployments.get(`Pool-Proxy-${MARKET_NAME}`)).address, [
    "function getReservesList() view returns (address[])", "function getConfiguration(address) view returns (uint256)",
  ]);
  const oracleArtifact = await hre.deployments.get(`AaveOracle-${MARKET_NAME}`);
  const oracle = await hre.ethers.getContractAt(oracleArtifact.abi, oracleArtifact.address);
  const free = async (id: number, who: string) => BigInt((await api.call.currenciesApi.account(id, who)).free.toString());
  const govAccount = await nativeAccount(api, admin);
  const treasury = api.registry.createType("AccountId", u8aConcat(stringToU8a("modl"), api.consts.treasury.palletId.toU8a(), new Uint8Array(20))).toString();
  const fromTreasury = (label: string, dest: string, id: number, amount: bigint) =>
    sub(`treasury → ${label}: ${amount} of asset ${id}`, hydrationTx.dispatcher.dispatchAsTreasury(hydrationTx.currencies.transfer(dest, id, amount.toString())));

  // ═════ chain: PRIME pool fee, compound routes, the synthetic listed and configured, the share assets ═════
  // Pure substrate (no aave-manager wrapper) — forceInsertRoute and updatePoolFee are Root calls.
  step = "chain";
  const primePool: any = await api.query.stableswap.pools(ROUTE_POOL);
  if (!primePool.isSome) throw new Error(`stableswap pool ${ROUTE_POOL} not found`);
  const primePoolFee = primePool.unwrap().fee.toNumber();
  if (primePoolFee !== ROUTE_POOL_FEE_PPM) sub(`stableswap.updatePoolFee(${ROUTE_POOL}, ${primePoolFee} → ${ROUTE_POOL_FEE_PPM} ppm)`, hydrationTx.stableswap.updatePoolFee(ROUTE_POOL, ROUTE_POOL_FEE_PPM));
  // the default routes follow the vaults' collateral; another vault brings its own with its own referendum
  const collaterals = new Set(rows.map((r) => r.assetId));
  const harvestRoutes = [
    ...COMPOUND_ROUTES.filter((r) => process.env.JUICER_COMPOUND_ROUTES || collaterals.has(r.assetOut)).map((r) => ({ assetIn: ROUTE_PRIME, ...r })),
    ...OPERATING_ROUTES.filter((r) => process.env.JUICER_OPERATING_ROUTES || collaterals.has(r.assetIn)),
  ];
  for (const { assetIn, assetOut, route } of harvestRoutes) {
    // The router CANONICALISES the pair: it stores under (min, max) and reverses the hops, so query that key.
    const existing: any = await api.query.router.routes(assetIn < assetOut ? { assetIn, assetOut } : { assetIn: assetOut, assetOut: assetIn });
    if (existing?.isSome) continue;
    sub(`router.forceInsertRoute(${assetIn} → ${assetOut}, ${route.length} hops)`, hydrationTx.router.forceInsertRoute({ assetIn, assetOut }, route));
  }
  // Substrate registration MUST precede the EVM initReserves: the precompile reads decimals from the registry.
  if ((await api.query.assetRegistry.assets(SYNTH_ASSET_ID)).isNone) {
    sub(`register synthetic (asset ${SYNTH_ASSET_ID}) as Erc20 → ${synth}`, hydrationTx.assetRegistry.register(
      // `assetRegistry.assetIds` is a unique index keyed on NAME, so a lark redeploy overrides it.
      SYNTH_ASSET_ID, SYNTH_ASSET_NAME, "Erc20", "10000000000000000", "jsHOLLAR", 18, location(synth), null, true));
  }
  // dispatchAsAaveManager swallows EVM reverts as ExecutedFailed events, so a re-run must not repeat a listing.
  const listed = (await pool.getReservesList()).some((a: string) => same(a, synth));
  if (!listed) {
    const aTokenImpl = (await hre.deployments.get(`AToken-${MARKET_NAME}`)).address;
    const stableDebtImpl = (await hre.deployments.get(`StableDebtToken-${MARKET_NAME}`)).address;
    const variableDebtImpl = (await hre.deployments.get(`VariableDebtToken-${MARKET_NAME}`)).address;
    const rateStrategy = (await hre.deployments.get("ReserveStrategy-rateStrategyStables")).address;
    const aaveTreasury = (await hre.deployments.get(TREASURY_PROXY_ID)).address;
    const incentives = (await hre.deployments.get("IncentivesProxy")).address;
    const tx = await poolConfigurator.populateTransaction.initReserves([{
      aTokenImpl, stableDebtTokenImpl: stableDebtImpl, variableDebtTokenImpl: variableDebtImpl, underlyingAssetDecimals: 18,
      interestRateStrategyAddress: rateStrategy, underlyingAsset: synth, treasury: aaveTreasury, incentivesController: incentives,
      aTokenName: "Juicer aSynth", aTokenSymbol: "aJSYNTH", variableDebtTokenName: "Juicer Variable Debt Synth",
      variableDebtTokenSymbol: "vdJSYNTH", stableDebtTokenName: "Juicer Stable Debt Synth", stableDebtTokenSymbol: "sdJSYNTH", params: "0x",
    }]);
    evm("initReserves(synthetic)", tx.to, tx.data, 10_000_000);
  }
  const config = listed ? BigInt((await pool.getConfiguration(synth)).toString()) : 0n;
  const bits = (from: number, width: number) => Number((config >> BigInt(from)) & ((1n << BigInt(width)) - 1n));
  if (!listed || bits(0, 16) !== Number(SYNTH_LTV) || bits(16, 16) !== Number(SYNTH_LT) || bits(32, 16) !== Number(SYNTH_BONUS)) {
    const tx = await poolConfigurator.populateTransaction.configureReserveAsCollateral(synth, SYNTH_LTV, SYNTH_LT, SYNTH_BONUS);
    evm(`configureReserveAsCollateral(LTV ${SYNTH_LTV}, LT ${SYNTH_LT}, bonus ${SYNTH_BONUS})`, tx.to, tx.data);
  }
  if (!listed || bits(58, 1) !== 0) {
    const tx = await poolConfigurator.populateTransaction.setReserveBorrowing(synth, false);
    evm("setReserveBorrowing(synthetic, false)", tx.to, tx.data);
  }
  if (!listed || bits(116, 36) !== Number(SYNTH_SUPPLY_CAP)) {
    const tx = await poolConfigurator.populateTransaction.setSupplyCap(synth, SYNTH_SUPPLY_CAP);
    evm("setSupplyCap(synthetic, unlimited)", tx.to, tx.data);
  }
  if (!same(await oracle.getSourceOfAsset(synth), GHO_ORACLE_ADDRESS)) {
    evm("setAssetSources(synthetic → $1 fixed oracle)", oracle.address, oracle.interface.encodeFunctionData("setAssetSources", [[synth], [GHO_ORACLE_ADDRESS]]), 1_000_000);
  }
  // each vault's share as a sufficient Erc20 asset after the synthetic's id, with its collateral's existential deposit
  const shareIds = list(process.env.JUICER_SHARE_ASSET_IDS).map(Number);
  for (const [i, r] of rows.entries()) {
    const known: any = await api.query.assetRegistry.locationAssets(location(r.address));
    if (known.isSome) continue;
    const id = shareIds[i] ?? SYNTH_ASSET_ID + 1 + i, name = await r.c.name();
    if ((await api.query.assetRegistry.assets(id)).isSome) throw new Error(`share asset id ${id} is taken`);
    if ((await api.query.assetRegistry.assetIds(name)).isSome) throw new Error(`asset name ${name} is taken`);
    const ed = (await api.query.assetRegistry.assets(r.assetId)).unwrap().existentialDeposit.toString();
    sub(`register share ${await r.c.symbol()} (asset ${id}) as Erc20 → ${r.address}`,
      hydrationTx.assetRegistry.register(id, name, "Erc20", ed, await r.c.symbol(), await r.c.decimals(), location(r.address), null, true));
  }

  // ═════ custody: dust protection precedes every transfer into Juicer contracts ═════
  step = "custody";
  for (const custody of [subLoop, harvester, fees, ...rows.flatMap((r) => [r.address, r.mainDebt, r.yieldAccounting]), ...(swapper ? [swapper] : [])]) {
    const account = await nativeAccount(api, custody);
    if ((await api.query.duster.accountWhitelist(account)).isNone) sub(`duster.whitelistAccount(${custody})`, hydrationTx.duster.whitelistAccount(account));
  }

  // ═════ funding: governance's collateral and HOLLAR, the loop's callback fees ═════
  // governance's EVM caller pays the rounding donations, the reserve and the bootstrap, from the treasury by
  // dispatcher.dispatchAsTreasury (Root or Treasurer, signs as the treasury); JUICER_FUNDING_SOURCE=admin: prefunded
  step = "funding";
  const bootstrapUnits = new Map<string, bigint>(), roundingUnits = new Map<string, bigint>();
  for (const r of rows) {
    const policy = rounding.get(r.address.toLowerCase());
    if (!policy) throw new Error(`no rounding policy for ${r.address}`);
    await nativeRoundingPolicy(api, policy, r.asset);
    const reserve = BigInt((await r.c.roundingReserve()).toString());
    roundingUnits.set(r.address, policy.target > reserve ? policy.target - reserve : 0n);
    const seed = BigInt(utils.parseUnits(process.env.JUICER_BOOTSTRAP || LAUNCH.bootstrap, await r.c.decimals()).toString());
    bootstrapUnits.set(r.address, (await r.c.totalSupply()).isZero() ? seed : 0n);
  }
  const reserveHollar = process.env.JUICER_RESERVE_HOLLAR ?? NEXT.reserveHollar;
  const reserveTarget = utils.parseUnits(reserveHollar, 18);
  const reserveHeld = await Promise.all(rows.map(async (r) => (await at(r.mainDebt, ["function protocolReserve() view returns (uint256)"])).protocolReserve()));
  const reserveShort = reserveHeld.reduce((a, held) => a + (reserveTarget.gt(held) ? BigInt(reserveTarget.sub(held).toString()) : 0n), 0n);
  const wants = new Map<number, bigint>();
  for (const r of rows) wants.set(r.assetId, (wants.get(r.assetId) ?? 0n) + roundingUnits.get(r.address)! + bootstrapUnits.get(r.address)!);
  wants.set(ROUTE_HOLLAR, (wants.get(ROUTE_HOLLAR) ?? 0n) + reserveShort);
  const planned = new Map<number, bigint>();
  for (const [id, amount] of wants) {
    const held = await free(id, govAccount), short = amount > held ? amount - held : 0n;
    planned.set(id, held + short);
    if (short === 0n) continue;
    if (fundingSource === "admin") throw new Error(`Prefund Aave manager ${admin} with ${short} base units of asset ${id}`);
    if ((await free(id, treasury)) < short) throw new Error(`the treasury holds less than ${short} of asset ${id}`);
    fromTreasury(`governance ${admin}`, govAccount, id, short);
  }
  // the loop's ICE callbacks pay in WETH: its fee currency reset to WETH, and HDX so a first deposit never moves it
  const loopAccount = await nativeAccount(api, subLoop);
  if ((await api.query.multiTransactionPayment.accountCurrencyMap(loopAccount)).unwrapOr(null)?.toNumber() !== 20) {
    sub(`multiTransactionPayment.resetPaymentCurrency(loop ${loopAccount})`, hydrationTx.multiTransactionPayment.resetPaymentCurrency(loopAccount));
  }
  if ((await free(0, loopAccount)) === 0n) fromTreasury(`loop ${subLoop}`, loopAccount, 0, BigInt(LAUNCH.iceHdx.toString()));
  const loopWeth = await free(20, loopAccount), iceWeth = BigInt(LAUNCH.iceWeth.toString());
  if (loopWeth * 2n < iceWeth) fromTreasury(`loop ${subLoop}`, loopAccount, 20, iceWeth - loopWeth);

  // ═════ wire: synthetic minting, the Main ledgers, fees, harvest, the loop's route, guardians, the adapter ═════
  step = "wire";
  const harvC = await at(harvester, ["function feeController() view returns (address)", "function isRegistered(address) view returns (bool)"]);
  const feesC = await at(fees, ["function bindings(address) view returns (address asset,address harvester,uint16 feeBps)"]);
  const synthC = await at(synth, ["function hasRole(bytes32,address) view returns (bool)"]);
  const tranches = [utils.parseUnits(DEPLOY_TRANCHE, 18), utils.parseUnits(UNWIND_TRANCHE, 6)];
  if (!(await loopC.deployTranche()).eq(tranches[0]) || !(await loopC.unwindTranche()).eq(tranches[1])) {
    evm(`subLoop.setTranches(${DEPLOY_TRANCHE} HOLLAR, ${UNWIND_TRANCHE} aPRIME)`, subLoop, loopI.encodeFunctionData("setTranches", tranches));
  }
  const dca = [ROUTE_HOLLAR, ROUTE_PRIME, ROUTE_APRIME, ROUTE_POOL, ROUTE_SLIPPAGE_PPM];
  const liveDca = [await loopC.hollarAssetId(), await loopC.primeAssetId(), await loopC.aPrimeAssetId(), await loopC.primePoolId(), await loopC.dcaSlippagePpm()];
  if (dca.some((x, i) => x !== Number(liveDca[i]))) evm(`subLoop.configureDca(${dca.join(", ")})`, subLoop, loopI.encodeFunctionData("configureDca", dca));
  // before the fee binding, which checks it, and before anything can call harvest(): SubLoop.harvest reverts HarvesterUnset without it
  if (!same(await loopC.harvester(), harvester)) evm(`subLoop.setHarvester(${harvester})`, subLoop, loopI.encodeFunctionData("setHarvester", [harvester]));
  if (!same(await harvC.feeController(), fees)) evm(`harvester.setFeeController(${fees})`, harvester, vaultI.encodeFunctionData("setFeeController", [fees]));
  for (const r of rows) {
    if (!(await synthC.hasRole(MINTER, r.address))) evm(`synth.grantRole(MINTER_ROLE, ${r.address})`, synth, accessI.encodeFunctionData("grantRole", [MINTER, r.address]));
    if (!(await loopC.hasRole(VAULT, r.address))) evm(`subLoop.registerVault(${r.address})`, subLoop, loopI.encodeFunctionData("registerVault", [r.address]));
    // deployment-only: the ledger binds while the vault has no shares
    if (r.bound === constants.AddressZero) evm(`vault ${r.address}.setMainDebt(${r.mainDebt})`, r.address, vaultI.encodeFunctionData("setMainDebt", [r.mainDebt]));
    if (!same(await r.c.feeController(), fees)) evm(`vault ${r.address}.setFeeController(${fees})`, r.address, vaultI.encodeFunctionData("setFeeController", [fees]));
    const binding = await feesC.bindings(r.address);
    if (binding.asset === constants.AddressZero || !same(binding.harvester, harvester)) {
      evm(`fees.registerVault(${r.address}, ${harvester})`, fees, iface(["function registerVault(address,address)"]).encodeFunctionData("registerVault", [r.address, harvester]));
    }
    if (!(await harvC.isRegistered(r.address))) evm(`harvester.addVault(${r.address})`, harvester, iface(["function addVault(address)"]).encodeFunctionData("addVault", [r.address]));
    if ((await r.c.compoundSlippageBps()) !== COMPOUND_SLIPPAGE_BPS) {
      evm(`vault ${r.address}.setCompoundSlippageBps(${COMPOUND_SLIPPAGE_BPS})`, r.address, vaultI.encodeFunctionData("setCompoundSlippageBps", [COMPOUND_SLIPPAGE_BPS]));
    }
    if ((await r.c.withdrawalDelay()) !== withdrawalDelay) evm(`vault ${r.address}.setWithdrawalDelay(${withdrawalDelay})`, r.address, vaultI.encodeFunctionData("setWithdrawalDelay", [withdrawalDelay]));
    if (swapper && !same(await r.c.swapper(), swapper)) evm(`vault ${r.address}.setSwapper(${swapper})`, r.address, vaultI.encodeFunctionData("setSwapper", [swapper]));
  }
  // Two-tier governance: ADMIN stays with the slow track, GUARDIAN (pause only) also goes to the committee.
  for (const target of [subLoop, ...vaults]) {
    if (!(await (await at(target, VAULT_ABI)).hasRole(GUARDIAN, guardian))) evm(`${target}.grantRole(GUARDIAN_ROLE, ${guardian})`, target, accessI.encodeFunctionData("grantRole", [GUARDIAN, guardian]));
  }
  // the adapter routes by asset id: PRIME and each collateral in, HOLLAR out
  if (swapper) {
    const adapter = await at(swapper, ["function owner() view returns (address)", "function pendingOwner() view returns (address)",
      "function acceptOwnership()", "function assetId(address) view returns (uint32)", "function setAssetId(address,uint32)"]);
    // the deployer hands it over before proposing; a two-step owner leaves the acceptance to governance
    if (!same(await adapter.owner(), admin)) {
      const pending = await adapter.pendingOwner().catch(() => undefined);
      if (!same(pending, admin)) throw new Error(`the adapter ${swapper} is neither owned by nor pending to governance: the deployer transfers it before proposing`);
      evm("adapter.acceptOwnership()", swapper, adapter.interface.encodeFunctionData("acceptOwnership"));
    }
    for (const [address, id] of [[prime, ROUTE_PRIME], [hollar, ROUTE_HOLLAR], ...rows.map((r) => [r.asset, r.assetId])] as [string, number][]) {
      if (Number(await adapter.assetId(address)) !== id) evm(`adapter.setAssetId(${address}, ${id})`, swapper, adapter.interface.encodeFunctionData("setAssetId", [address, id]));
    }
  }

  // ═════ execution: budgets, lanes and prices, quote entrypoints, then every consumer bound ═════
  step = "execution";
  const quotes = await at(controller, ["function maxQuoteAge() view returns (uint64)", "function maxQuoteBlocks() view returns (uint64)"]);
  const now = Math.floor(Number((await api.query.timestamp.now()).toString()) / 1000);
  const expiresAt = envNumber("JUICER_POLICY_EXPIRES_AT", now + LAUNCH.expiryDays * 86400);
  const policy = executionPolicy({ subLoop, harvester, hollar, prime, aPrime, vaults: rows.map((r) => ({ address: r.address, mainDebt: r.mainDebt, collateral: r.asset, assetId: r.assetId, key: r.key })) }, {
    expiresAt, pacing: LAUNCH.pacing, primeShortfallBps: ROUTE_SLIPPAGE_PPM / 100,
    collateralShortfallBps: envNumber("JUICER_COLLATERAL_SHORTFALL_BPS", LAUNCH.collateralShortfallBps),
    entry: LAUNCH.entry, unwind: LAUNCH.unwind, harvest: LAUNCH.harvest, service: LAUNCH.service,
  }, { age: Number(await quotes.maxQuoteAge()), blocks: Number(await quotes.maxQuoteBlocks()) });
  if (policy.limits.some((l) => l.name.startsWith("harvest") && l.maxShortfallBps > COMPOUND_SLIPPAGE_BPS)) {
    throw new Error("the vaults' compound floor must permit the harvest lanes' shortfall");
  }
  plan(executionCalls(await readExecution(hre.ethers.provider, controller, policy), policy));

  // ═════ discount: deployed with the rest against the synthetic's predicted aToken; installed, vaults and the loop enrolled ═════
  step = "discount";
  const reserveData = await at(pool.address, ["function getReserveData(address) view returns ((uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128))"]);
  const debtToken = (await reserveData.getReserveData(hollar))[10];
  const discountState = await readDiscount(hre.ethers.provider, { discount, debtToken, vaults });
  if (!discountState.code) throw new Error(`no JuicerDiscount at ${discount}: scripts/juicer/launch-deploy.mjs deploys it`);
  const discountC = await at(discount, ["function aSynthetic() view returns (address)", "function synthetic() view returns (address)",
    "function debtToken() view returns (address)", "function hasRole(bytes32,address) view returns (bool)"]);
  if (!same(await discountC.synthetic(), synth) || !same(await discountC.debtToken(), debtToken) || !(await discountC.hasRole(constants.HashZero, admin))) {
    throw new Error(`${discount} is not this launch's discount`);
  }
  const boundAToken = await discountC.aSynthetic();
  let prediction = "";
  if (listed) {
    const aToken = (await reserveData.getReserveData(synth))[8];
    if (!same(aToken, boundAToken)) throw new Error(`the discount is bound to ${boundAToken}, the synthetic's aToken is ${aToken}`);
  } else {
    // initReserves creates the aToken first, from the configurator: its next creation unless another listing goes first
    const creatorNonce = await hre.ethers.provider.getTransactionCount(poolConfigurator.address);
    const next = utils.getContractAddress({ from: poolConfigurator.address, nonce: creatorNonce });
    if (!same(next, boundAToken)) {
      throw new Error(`the discount is bound to ${boundAToken}, but the synthetic's aToken would now be ${next} (configurator nonce ${creatorNonce}): ` +
        "a listing moved it since the deploy; rerun scripts/juicer/launch-deploy.mjs for a new discount, then regenerate");
    }
    prediction = `The discount is bound to ${next}, the configurator's creation at nonce ${creatorNonce}: the synthetic's aToken as
long as no other listing is enacted before this referendum's initReserves. One that is moves it and leaves
the discount reading the wrong token: regenerate (this check refuses) and redeploy the discount first.`;
  }
  const loopCap = utils.parseUnits(process.env.JUICER_LOOP_DISCOUNT_CAP || utils.formatUnits(LAUNCH.loopCap, 18), 18);
  plan(discountCalls(discountState, { discount, debtToken, subLoop, loopCap }));

  // ═════ next: keepers, harvest threshold, ICE, bands, admission, headroom exits, revenue mix ═════
  // Keepers get SubLoop KEEPER_ROLE (quoted pokes) and each vault's DEPOSIT_GUARDIAN_ROLE (setDeficitStop only).
  // The bands are converted against each collateral's live max LTV; the rates need the discount installed.
  step = "next";
  const mainDebts = Object.fromEntries(rows.map((r) => [r.address.toLowerCase(), r.mainDebt]));
  const nextState = assumePlanned(
    await readNextState(hre.ethers.provider, { subLoop, vaults, controller, keepers, discount: discountState.code ? discount : undefined, fees, mainDebts }),
    { policy, discount: { address: discount, loop: subLoop }, feeBps: 500 });
  const expected = {
    keepers,
    harvestThreshold: process.env.JUICER_HARVEST_THRESHOLD || NEXT.harvestThreshold,
    intentTtl: envNumber("JUICER_INTENT_TTL", NEXT.intentTtl),
    intentDriftBps: envNumber("JUICER_INTENT_DRIFT_BPS", NEXT.intentDriftBps),
    band: process.env.JUICER_REBALANCE_BAND ? parseBand(process.env.JUICER_REBALANCE_BAND) : NEXT.band,
    admissionMaxDeficitBps: envNumber("JUICER_ADMISSION_MAX_DEFICIT_BPS", NEXT.admissionMaxDeficitBps),
    exitHeadroom: process.env.JUICER_EXIT_HEADROOM !== undefined ? parseExitHeadroom(process.env.JUICER_EXIT_HEADROOM) : NEXT.exitHeadroom,
    revenue: {
      protocolFeeBps: envNumber("JUICER_PROTOCOL_FEE_BPS", NEXT.revenue.protocolFeeBps),
      mainDiscountBps: envNumber("JUICER_DISCOUNT_BPS", NEXT.revenue.mainDiscountBps),
      loopDiscountBps: envNumber("JUICER_LOOP_DISCOUNT_BPS", NEXT.revenue.loopDiscountBps),
    },
  };
  plan(nextCalls(nextState, expected));

  // ═════ reserve: each Main ledger's protocol reserve, which covers a headroom exit's shortfall ═════
  step = "reserve";
  if (!reserveTarget.isZero()) {
    plan(reserveCalls({
      hollar, payer: admin, amount: reserveTarget, payerBalance: (planned.get(ROUTE_HOLLAR) ?? 0n).toString(),
      ledgers: rows.map((r, i) => ({ address: r.mainDebt, held: reserveHeld[i] })),
    }));
  }

  // ═════ rounding: collateral donated to each vault's rounding reserve ═════
  step = "rounding";
  for (const r of rows) {
    const amount = roundingUnits.get(r.address)!;
    if (amount === 0n) continue;
    evm(`collateral.approve(${r.address}, 0)`, r.asset, tokenI.encodeFunctionData("approve", [r.address, 0]));
    evm(`collateral.approve(${r.address}, ${amount})`, r.asset, tokenI.encodeFunctionData("approve", [r.address, amount]));
    evm(`vault ${r.address}.fundRoundingReserve(${amount})`, r.address, vaultI.encodeFunctionData("fundRoundingReserve", [amount]));
    evm(`collateral.approve(${r.address}, 0)`, r.asset, tokenI.encodeFunctionData("approve", [r.address, 0]));
  }

  // ═════ open: governance's bootstrap deposit, last; the first public deposit reverts until it lands ═════
  step = "open";
  const receiver = process.env.JUICER_BOOTSTRAP_RECEIVER || admin;
  for (const r of rows) {
    plan(bootstrapCalls({ vault: r.address, asset: r.asset, seed: bootstrapUnits.get(r.address)!.toString(), receiver,
      supply: await r.c.totalSupply(), paused: await r.c.depositsPaused() }));
  }

  // ── batches: in order, each within a share of the scheduler's block weight ──
  const calls = await Promise.all(items.map((i) => i.tx ?? aaveManagerCall({ to: i.evm!.to, data: i.evm!.data, gasLimit: i.evm!.gas, from: admin })));
  const weigh = async (call: any) => {
    const w = (await call.paymentInfo(govAccount)).weight;
    return { ref: BigInt(w.refTime.toString()), proof: BigInt(w.proofSize.toString()) };
  };
  const weights = await Promise.all(calls.map(weigh));
  const max = api.consts.scheduler.maximumWeight;
  const pct = BigInt(envNumber("JUICER_BATCH_WEIGHT_PCT", 40));
  const budget = { ref: BigInt(max.refTime.toString()) * pct / 100n, proof: BigInt(max.proofSize.toString()) * pct / 100n };
  const scheduling = await weigh(hydrationTx.scheduler.scheduleAfter(0, null, 0, hydrationTx.system.remark("0x")));
  const pack = (reserved: number) => {
    const out: number[][] = [[]];
    let ref = scheduling.ref * BigInt(reserved), proof = scheduling.proof * BigInt(reserved);
    for (const [i, w] of weights.entries()) {
      if (out.at(-1)!.length && (ref + w.ref > budget.ref || proof + w.proof > budget.proof)) { out.push([]); ref = 0n; proof = 0n; }
      if (w.ref > budget.ref || w.proof > budget.proof) throw new Error(`${items[i].label} alone exceeds the batch weight budget`);
      out.at(-1)!.push(i); ref += w.ref; proof += w.proof;
    }
    return out;
  };
  // the enactment batch also schedules every later one
  let groups = pack(0);
  for (let reserved = groups.length; ; reserved = groups.length) {
    groups = pack(reserved);
    if (groups.length <= reserved) break;
  }
  const writePlan = (proposal: any, batches: any[]) => {
    if (!process.env.JUICER_PLAN_OUT) return;
    writeFileSync(process.env.JUICER_PLAN_OUT, JSON.stringify({
      proposal, batches, policy, expiresAt, discount, keepers, governance: admin,
      values: {
        slippagePpm: ROUTE_SLIPPAGE_PPM, primePoolFeePpm: ROUTE_POOL_FEE_PPM, withdrawalDelay, synthAssetId: SYNTH_ASSET_ID,
        harvestThreshold: expected.harvestThreshold.toString(), intentTtl: expected.intentTtl, intentDriftBps: expected.intentDriftBps,
        band: expected.band, admissionMaxDeficitBps: expected.admissionMaxDeficitBps, exitHeadroom: expected.exitHeadroom, revenue: expected.revenue,
        reserveHollar, loopCapHollar: utils.formatUnits(loopCap, 18).replace(/\.0$/, ""),
      },
    }, (_, x) => typeof x === "bigint" ? x.toString() : x, 2) + "\n");
    console.log(`plan written to ${process.env.JUICER_PLAN_OUT}`);
  };
  if (!groups[0].length) {
    console.log("\nnothing to propose: the chain already has every launch call");
    writePlan(null, []);
    return;
  }

  const decoder = new ProposalDecoder(hre);
  await decoder.init();
  const fraction = (w: { ref: bigint; proof: bigint }) =>
    `${Number(w.ref * 10000n / BigInt(max.refTime.toString())) / 100}% ref, ${Number(w.proof * 10000n / BigInt(max.proofSize.toString())) / 100}% proof of the scheduler's`;
  const batches = [];
  for (const [n, group] of groups.entries()) {
    const call = hydrationTx.utility.batchAll(group.map((i) => calls[i]));
    const weight = await weigh(call);
    const steps = [...new Set(group.map((i) => items[i].step))];
    const label = `BATCH ${n} — ${steps.join(", ")}`;
    batches.push({ label, offset: n, steps, call, weight, labels: group.map((i) => items[i].label) });
    console.log(`\n===== ${label} (${group.length} calls, ${call.method.encodedLength} bytes, weight ${weight.ref} / ${weight.proof}: ${fraction(weight)}) =====`);
    decoder.printTree(decoder.transformCall(call.method.toHuman()));
  }
  // scheduleAfter(n) runs at enactment + 1 + n, so each later batch gets a block to itself
  const later = batches.slice(1);
  const proposal = hydrationTx.utility.batchAll([
    ...groups[0].map((i) => calls[i]),
    ...later.map((b, i) => hydrationTx.scheduler.scheduleAfter(i, null, 0, b.call)),
  ]);
  const enactment = await weigh(proposal);
  console.log(`\n===== PROPOSAL — BATCH 0 on enactment${later.map((b) => `, BATCH ${b.offset} at +${b.offset}`).join("")} (${proposal.method.encodedLength} bytes, enactment weight ${enactment.ref} / ${enactment.proof}: ${fraction(enactment)}) =====`);
  console.log(proposal.method.toHex());
  console.log(`\n===== PROPOSAL hash ${proposal.method.hash.toHex()} =====`);
  writePlan({ hash: proposal.method.hash.toHex(), len: proposal.method.encodedLength, hex: proposal.method.toHex(), enactmentWeight: enactment },
    batches.map(({ call, ...b }) => ({ ...b, bytes: call.method.encodedLength })));

  console.log(`
Submit the PROPOSAL as ONE Root referendum. BATCH 0 runs on enactment and every later batch on the
blocks after it, in order, each within ${pct}% of the scheduler's block weight (a batch above it trips
scheduler.PermanentlyOverweight). A failed batch does not stop the next one: check each block's events.

dispatcher.dispatchAsAaveManager reports EVM reverts as ExecutedFailed EVENTS and
dispatcher.dispatchAsTreasury its inner result in TreasuryManagerCallDispatched, not as failures,
so a batch can "succeed" with calls silently reverted. After enactment run
scripts/juicer/verify-readiness.ts with JUICER_EXECUTION_POLICY from JUICER_PLAN_OUT before announcing.
The execution policy expires at ${expiresAt} (JUICER_POLICY_EXPIRES_AT pins it across reruns).
${prediction}
`);
});
