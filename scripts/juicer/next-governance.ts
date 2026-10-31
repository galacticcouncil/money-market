// The next version's governance surface, shared by the mainnet proposal and the readiness
// checker: keeper roles, the harvest threshold, ICE, rebalance bands, deposit admission, headroom exits, the revenue mix and the protocol reserve.
// One reader, then pure planning: callers get back only the calls still missing, or the checks.
import { BigNumber, BigNumberish, Contract, constants, utils } from "ethers";

export const NEXT = {
  // ~0.02% of principal per harvest
  harvestThreshold: BigNumber.from("200000000000000"),
  // seconds: the loop sets each deadline to (block.timestamp + ttl) * 1000 ms, under a day
  intentTtl: 300,
  // keeper-quote tolerance beside the solver's 1 bp haircut
  intentDriftBps: 2,
  reserveHollar: "1000",
  // LTV bps on every vault: relever below, borrow to, delever above
  band: { relever: 6500, target: 7500, delever: 8300 },
  // deposits close above this source deficit; levering a deposit to the target costs ~50 bps,
  // the contract default, so at 50 the loop's own entry cost closes them (lark 0, 22 oct: 6.5 h)
  admissionMaxDeficitBps: 250,
  // exits settle from each vault's LTV headroom without selling the loop, up to the max LTV
  exitHeadroom: { enabled: true, gapBps: 0 },
  // PRIME/HOLLAR stableswap fee at launch, Permill: 1 bp, from 4
  primePoolFeePpm: 100,
  // ~80% of treasury income in collateral: juicenomics at $450k, 21 Oct (81.4% closed form,
  // 80.6% Monte Carlo); users as with a 5% fee and no discounts. the loop takes most of the
  // discount: Main interest is repaid from every harvest, loop interest only when the loop repays
  revenue: { protocolFeeBps: 6900, mainDiscountBps: 4000, loopDiscountBps: 9000 },
};
/// an empty variable is a mistake, not a zero: unset takes the fallback, anything set must be a number
export function envNumber(name: string, fallback: number, env: Record<string, string | undefined> = process.env): number {
  const raw = env[name];
  if (raw === undefined) return fallback;
  if (raw.trim() === "") throw new Error(`${name} is set but empty`);
  const value = Number(raw);
  if (!Number.isFinite(value)) throw new Error(`${name}=${raw} is not a number`);
  return value;
}
export const KEEPER_ROLE = utils.id("KEEPER_ROLE");
export const DEPOSIT_GUARDIAN_ROLE = utils.id("DEPOSIT_GUARDIAN_ROLE");
export const GUARDIAN_ROLE = utils.id("GUARDIAN_ROLE");
export const ADMIN_ROLE = utils.id("ADMIN_ROLE");

const access = new utils.Interface(["function grantRole(bytes32,address)"]);
const loopI = new utils.Interface([
  "function setParams(uint256,uint256,uint256,uint256)",
  "function configureIntents(uint32,uint16)",
  "function setRebalanceBand(address,uint16,uint16,uint16)",
  "function setAdmissionMaxDeficitBps(uint16)",
  "function setExitHeadroom(address,bool,uint16)",
]);
const controlI = new utils.Interface(["function configureAsync(bytes32,bool)"]);
const discountI = new utils.Interface(["function setDiscountBps(uint16)", "function setLoopDiscountBps(uint16)"]);
const feesI = new utils.Interface(["function setProtocolFeeBps(address,uint16)"]);
const tokenI = new utils.Interface(["function approve(address,uint256) returns (bool)", "function mint(address,uint256)"]);
const ledgerI = new utils.Interface(["function fundReserve(uint256)"]);

export type Call = { to: string; data: string; label: string; gas?: number };
export type Check = { name: string; ok: boolean; detail?: string };
type Roles = Record<string, { keeper?: boolean; guardian?: boolean; admin?: boolean }>;
export type Band = { relever: number; target: number; delever: number };
export type ExitHeadroom = { enabled: boolean; gapBps: number };
export type Revenue = { protocolFeeBps: number; mainDiscountBps: number; loopDiscountBps: number };
export type NextState = {
  subLoop: {
    address: string;
    targetHf: BigNumber; deployHfFloor: BigNumber; deLeverTrigger: BigNumber; harvestThreshold: BigNumber;
    // undefined: contracts without that part of the surface
    intentTtl?: number; intentDriftBps?: number; keeperRole?: string; keepers: Roles; admissionMaxDeficitBps?: number;
  };
  vaults: {
    address: string; guardianRole?: string; keepers: Roles; mainDebt: string; protocolReserve?: BigNumber;
    // the loop's gaps (target below max LTV, relever below and delever above target), and the live max LTV
    gaps?: Band; maxLtv?: number; protocolFeeBps?: number; exitHeadroom?: ExitHeadroom;
  }[];
  discount?: { address: string; installed: boolean; discountBps?: number; loopDiscountBps?: number; loop?: string };
  fees?: string;
  controller?: { address: string; lanes: { name: string; lane: string; maximum: BigNumber; async?: boolean }[] };
};
export type Expected = {
  keepers?: string[]; harvestThreshold?: BigNumberish; intentTtl?: number; intentDriftBps?: number; reserve?: BigNumberish;
  band?: Band; revenue?: Revenue; admissionMaxDeficitBps?: number; exitHeadroom?: ExitHeadroom;
};

const showHeadroom = (h: ExitHeadroom) => h.enabled ? `on, ${h.gapBps} bps under max LTV` : "off";

/// "off", "on" or "on,500": headroom exits and their gap under max LTV in bps
export function parseExitHeadroom(text: string): ExitHeadroom {
  const [mode, gap, ...rest] = text.split(",").map(s => s.trim());
  if (rest.length || (mode !== "on" && mode !== "off") || (mode === "off" && gap !== undefined)) {
    throw new Error(`exit headroom "${text}": off, on, or on,<gap bps>`);
  }
  const gapBps = gap === undefined ? 0 : Number(gap);
  if (!(Number.isInteger(gapBps) && gapBps >= 0 && gapBps <= 10000)) throw new Error(`exit headroom gap "${gap}" out of range`);
  return { enabled: mode === "on", gapBps };
}

/// "6500,7500,8300": relever, target and delever LTVs in bps
export function parseBand(text: string): Band {
  const [relever, target, delever] = text.split(",").map(x => Number(x.trim()));
  return { relever, target, delever };
}

/// the loop keeps each band relative to the collateral's live max LTV, so governance changes move it
export function bandGaps(maxLtv: number, band: Band): Band {
  if (band.target > maxLtv || maxLtv - band.target > 5000) {
    throw new Error(`band target ${band.target} bps must sit within 50% under the max LTV ${maxLtv}`);
  }
  return { target: maxLtv - band.target, relever: band.target - band.relever, delever: band.delever - band.target };
}

const sameBand = (a: Band, b: Band) => a.relever === b.relever && a.target === b.target && a.delever === b.delever;
const showBand = (b: Band) => `${b.relever}/${b.target}/${b.delever}`;

async function maybe<T>(fn: () => Promise<T>): Promise<T | undefined> {
  try {
    return await fn();
  } catch {
    return undefined;
  }
}

export async function readNextState(provider: any, { subLoop, vaults, controller, keepers, discount, fees, mainDebts }:
  { subLoop: string; vaults: string[]; controller?: string; keepers: string[]; discount?: string; fees?: string;
    // the ledgers the launch binds, for vaults not bound yet
    mainDebts?: Record<string, string> }): Promise<NextState> {
  const loop = new Contract(subLoop, [
    "function targetHf() view returns (uint256)", "function deployHfFloor() view returns (uint256)",
    "function deLeverTrigger() view returns (uint256)", "function harvestThreshold() view returns (uint256)",
    "function intentTtl() view returns (uint32)", "function intentDriftBps() view returns (uint16)",
    "function KEEPER_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)",
    "function hollar() view returns (address)", "function primeAToken() view returns (address)",
    "function pool() view returns (address)", "function rebalanceBand(address) view returns (uint16,uint16,uint16)",
    "function admissionMaxDeficitBps() view returns (uint16)", "function exitHeadroom(address) view returns (bool,uint16)",
  ], provider);
  const pool = await maybe<string>(() => loop.pool());
  const reserves = pool && new Contract(pool, ["function getConfiguration(address) view returns (uint256)"], provider);
  const keeperRole = await maybe(() => loop.KEEPER_ROLE());
  const ttl = await maybe(() => loop.intentTtl()), drift = await maybe(() => loop.intentDriftBps());
  const admission = await maybe(() => loop.admissionMaxDeficitBps());
  const state: NextState = {
    subLoop: {
      address: subLoop,
      targetHf: await loop.targetHf(), deployHfFloor: await loop.deployHfFloor(),
      deLeverTrigger: await loop.deLeverTrigger(), harvestThreshold: await loop.harvestThreshold(),
      intentTtl: ttl === undefined ? undefined : Number(ttl), intentDriftBps: drift === undefined ? undefined : Number(drift),
      keeperRole, keepers: {}, admissionMaxDeficitBps: admission === undefined ? undefined : Number(admission),
    },
    vaults: [],
  };
  for (const k of keepers) state.subLoop.keepers[k] = { keeper: keeperRole ? await loop.hasRole(keeperRole, k) : undefined };
  for (const address of vaults) {
    const v = new Contract(address, [
      "function DEPOSIT_GUARDIAN_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)",
      "function mainDebt() view returns (address)", "function collateral() view returns (address)",
    ], provider);
    const guardianRole = await maybe(() => v.DEPOSIT_GUARDIAN_ROLE());
    const bound = await v.mainDebt();
    const mainDebt = bound === constants.AddressZero && mainDebts?.[address.toLowerCase()] ? mainDebts[address.toLowerCase()] : bound;
    const gaps = await maybe<number[]>(() => loop.rebalanceBand(address));
    const headroom = await maybe<[boolean, number]>(() => loop.exitHeadroom(address));
    const collateral = await maybe<string>(() => v.collateral());
    const config = reserves && collateral ? await maybe<BigNumber>(() => reserves.getConfiguration(collateral)) : undefined;
    const row = { address, guardianRole, keepers: {} as Roles, mainDebt,
      protocolReserve: await maybe(() => new Contract(mainDebt, ["function protocolReserve() view returns (uint256)"], provider).protocolReserve()),
      gaps: gaps && { target: Number(gaps[0]), relever: Number(gaps[1]), delever: Number(gaps[2]) },
      maxLtv: config === undefined ? undefined : BigNumber.from(config).and(0xffff).toNumber(),
      exitHeadroom: headroom && { enabled: headroom[0], gapBps: Number(headroom[1]) },
      protocolFeeBps: undefined as number | undefined };
    if (fees) {
      const fee = await maybe<number>(() => new Contract(fees, ["function protocolFeeBps(address) view returns (uint16)"], provider).protocolFeeBps(address));
      row.protocolFeeBps = fee === undefined ? undefined : Number(fee);
    }
    for (const k of keepers) {
      row.keepers[k] = {
        keeper: guardianRole ? await v.hasRole(guardianRole, k) : undefined,
        guardian: await v.hasRole(GUARDIAN_ROLE, k), admin: await v.hasRole(ADMIN_ROLE, k),
      };
    }
    state.vaults.push(row);
  }
  if (controller) {
    const c = new Contract(controller, [
      "function lane(address,address,address) pure returns (bytes32)",
      "function limits(bytes32) view returns (bytes32 group,uint128 minimum,uint128 maximum)",
      "function asyncLanes(bytes32) view returns (bool)",
    ], provider);
    const hollar = await loop.hollar(), aPrime = await loop.primeAToken();
    const lanes = [];
    for (const [name, input, output] of [["entry", hollar, aPrime], ["unwind", aPrime, hollar]]) {
      const lane = await c.lane(subLoop, input, output);
      lanes.push({ name, lane, maximum: (await c.limits(lane)).maximum, async: await maybe(() => c.asyncLanes(lane)) });
    }
    state.controller = { address: controller, lanes };
  }
  if (discount) {
    const d = new Contract(discount, [
      "function debtToken() view returns (address)", "function discountBps() view returns (uint16)",
      "function loopDiscountBps() view returns (uint16)", "function loop() view returns (address)",
    ], provider);
    const debt = new Contract(await d.debtToken(), [
      "function getDiscountToken() view returns (address)", "function getDiscountRateStrategy() view returns (address)",
    ], provider);
    const same = (a?: string) => !!a && a.toLowerCase() === discount.toLowerCase();
    const loopRate = await maybe<number>(() => d.loopDiscountBps());
    state.discount = {
      address: discount, installed: same(await maybe<string>(() => debt.getDiscountToken())) && same(await maybe<string>(() => debt.getDiscountRateStrategy())),
      discountBps: Number(await d.discountBps()), loopDiscountBps: loopRate === undefined ? undefined : Number(loopRate),
      loop: await maybe<string>(() => d.loop()),
    };
  }
  state.fees = fees;
  return state;
}

function validate(e: Expected) {
  if (e.intentTtl !== undefined && !(Number.isInteger(e.intentTtl) && e.intentTtl > 0 && e.intentTtl < 86400)) {
    throw new Error(`intent ttl ${e.intentTtl}: seconds, above 0 and under a day`);
  }
  if (e.intentDriftBps !== undefined && !(Number.isInteger(e.intentDriftBps) && e.intentDriftBps >= 0 && e.intentDriftBps < 9999)) {
    throw new Error(`intent drift ${e.intentDriftBps} bps out of range`);
  }
  if (e.harvestThreshold !== undefined) {
    const t = BigNumber.from(e.harvestThreshold);
    if (t.lte(0) || t.gte(utils.parseUnits("1", 18))) throw new Error("harvest threshold is a WAD fraction in (0, 1)");
  }
  for (const k of e.keepers ?? []) if (!utils.isAddress(k)) throw new Error(`keeper ${k} is not an address`);
  if (e.revenue !== undefined) {
    const rates = [e.revenue.protocolFeeBps, e.revenue.mainDiscountBps, e.revenue.loopDiscountBps];
    if (!rates.every(r => Number.isInteger(r) && r >= 0 && r <= 10000)) throw new Error("revenue mix rates are bps in 0..10000");
  }
  if (e.admissionMaxDeficitBps !== undefined && !(Number.isInteger(e.admissionMaxDeficitBps) && e.admissionMaxDeficitBps >= 0 && e.admissionMaxDeficitBps <= 10000)) {
    throw new Error(`admission deficit cap ${e.admissionMaxDeficitBps} bps out of range`);
  }
  if (e.exitHeadroom !== undefined && !(Number.isInteger(e.exitHeadroom.gapBps) && e.exitHeadroom.gapBps >= 0 && e.exitHeadroom.gapBps <= 10000)) {
    throw new Error(`exit headroom gap ${e.exitHeadroom.gapBps} bps out of range`);
  }
  if (e.band !== undefined) {
    const { relever, target, delever } = e.band;
    if (![relever, target, delever].every(Number.isInteger) || !(0 < relever && relever < target && target < delever)
        || target - relever > 5000 || delever - target > 2500) {
      throw new Error(`band ${showBand(e.band)} bps: relever < target < delever, at most 50% below and 25% above`);
    }
  }
}

const missingSurface = (what: string) => new Error(`${what} missing on chain: these are not the next version's contracts`);

/// keeper roles, the threshold, ICE, bands, admission, headroom exits and the revenue mix; the Main and vault wiring stays in the existing batches
export function nextCalls(state: NextState, e: Expected): Call[] {
  validate(e);
  const calls: Call[] = [];
  const loop = state.subLoop;
  for (const k of e.keepers ?? []) {
    if (!loop.keeperRole) throw missingSurface("SubLoop KEEPER_ROLE");
    if (!loop.keepers[k]?.keeper) {
      calls.push({ to: loop.address, data: access.encodeFunctionData("grantRole", [loop.keeperRole, k]), label: `subLoop.grantRole(KEEPER_ROLE, ${k})` });
    }
  }
  for (const v of state.vaults) {
    for (const k of e.keepers ?? []) {
      if (!v.guardianRole) throw missingSurface("vault DEPOSIT_GUARDIAN_ROLE");
      if (!v.keepers[k]?.keeper) {
        calls.push({ to: v.address, data: access.encodeFunctionData("grantRole", [v.guardianRole, k]), label: `vault ${v.address}.grantRole(DEPOSIT_GUARDIAN_ROLE, ${k})` });
      }
    }
  }
  if (e.harvestThreshold !== undefined && !loop.harvestThreshold.eq(e.harvestThreshold)) {
    // setParams rewrites all four; the other three keep their live values
    calls.push({ to: loop.address, label: `subLoop.setParams(…, harvestThreshold ${e.harvestThreshold})`,
      data: loopI.encodeFunctionData("setParams", [loop.targetHf, loop.deployHfFloor, loop.deLeverTrigger, e.harvestThreshold]) });
  }
  if (e.intentTtl !== undefined || e.intentDriftBps !== undefined) {
    if (loop.intentTtl === undefined) throw missingSurface("SubLoop intents");
    const ttl = e.intentTtl ?? loop.intentTtl, drift = e.intentDriftBps ?? loop.intentDriftBps;
    if (loop.intentTtl !== ttl || loop.intentDriftBps !== drift) {
      calls.push({ to: loop.address, data: loopI.encodeFunctionData("configureIntents", [ttl, drift]), label: `subLoop.configureIntents(${ttl} s, ${drift} bps)` });
    }
    if (!state.controller) throw new Error("ICE needs the execution controller (JUICER_EXECUTION_CONTROLLER)");
    for (const l of state.controller.lanes) {
      if (l.async === undefined) throw missingSurface("ExecutionController async lanes");
      if (l.maximum.isZero()) throw new Error(`the loop's ${l.name} lane has no limit: configure the execution lanes first`);
      if (!l.async) calls.push({ to: state.controller.address, data: controlI.encodeFunctionData("configureAsync", [l.lane, true]), label: `controller.configureAsync(${l.name} ${l.lane}, true)` });
    }
  }
  if (e.band !== undefined) {
    for (const v of state.vaults) {
      if (!v.gaps) throw missingSurface("SubLoop rebalanceBand");
      if (v.maxLtv === undefined) throw new Error(`${v.address}: the collateral's max LTV is unreadable`);
      const g = bandGaps(v.maxLtv, e.band);
      if (!sameBand(g, v.gaps)) {
        calls.push({ to: loop.address, data: loopI.encodeFunctionData("setRebalanceBand", [v.address, g.target, g.relever, g.delever]),
          label: `subLoop.setRebalanceBand(${v.address}, ${g.target}, ${g.relever}, ${g.delever}) → ${showBand(e.band)} under max ${v.maxLtv}` });
      }
    }
  }
  if (e.admissionMaxDeficitBps !== undefined) {
    if (loop.admissionMaxDeficitBps === undefined) throw missingSurface("SubLoop admissionMaxDeficitBps");
    if (loop.admissionMaxDeficitBps !== e.admissionMaxDeficitBps) {
      calls.push({ to: loop.address, data: loopI.encodeFunctionData("setAdmissionMaxDeficitBps", [e.admissionMaxDeficitBps]),
        label: `subLoop.setAdmissionMaxDeficitBps(${e.admissionMaxDeficitBps})` });
    }
  }
  if (e.exitHeadroom !== undefined) {
    const h = e.exitHeadroom;
    for (const v of state.vaults) {
      if (!v.exitHeadroom) throw missingSurface("SubLoop exitHeadroom");
      if (v.exitHeadroom.enabled !== h.enabled || v.exitHeadroom.gapBps !== h.gapBps) {
        calls.push({ to: loop.address, data: loopI.encodeFunctionData("setExitHeadroom", [v.address, h.enabled, h.gapBps]),
          label: `subLoop.setExitHeadroom(${v.address}, ${h.enabled}, ${h.gapBps})` });
      }
    }
  }
  if (e.revenue !== undefined) {
    // the rates only bite once the discount is installed and the loop enrolled; before that they would revert unseen
    const d = state.discount, r = e.revenue;
    if (!d || !state.fees) throw new Error("the revenue mix needs JUICER_DISCOUNT_CONTROLLER and JUICER_FEE_CONTROLLER");
    if (!d.installed) throw new Error("install JuicerDiscount on the HOLLAR debt token first (DeployDiscount.s.sol)");
    if (d.loopDiscountBps === undefined) throw missingSurface("JuicerDiscount loop rate");
    if (r.loopDiscountBps > 0 && !(d.loop && d.loop.toLowerCase() === loop.address.toLowerCase())) {
      throw new Error("enroll the loop in JuicerDiscount first (DISCOUNT_LOOP, DISCOUNT_LOOP_CAP)");
    }
    if (d.discountBps !== r.mainDiscountBps) {
      calls.push({ to: d.address, data: discountI.encodeFunctionData("setDiscountBps", [r.mainDiscountBps]), label: `discount.setDiscountBps(${r.mainDiscountBps})`, gas: 1_500_000 });
    }
    if (d.loopDiscountBps !== r.loopDiscountBps) {
      calls.push({ to: d.address, data: discountI.encodeFunctionData("setLoopDiscountBps", [r.loopDiscountBps]), label: `discount.setLoopDiscountBps(${r.loopDiscountBps})`, gas: 1_000_000 });
    }
    for (const v of state.vaults) {
      if (v.protocolFeeBps === undefined) throw new Error(`${v.address} is not registered in the fee controller`);
      if (v.protocolFeeBps !== r.protocolFeeBps) {
        calls.push({ to: state.fees, data: feesI.encodeFunctionData("setProtocolFeeBps", [v.address, r.protocolFeeBps]), label: `fees.setProtocolFeeBps(${v.address}, ${r.protocolFeeBps})` });
      }
    }
  }
  return calls;
}

/// the protocol reserve, a separate batch: `payer` (the governance EVM caller) holds the HOLLAR,
/// or mints it first from its own facilitator bucket
export function reserveCalls({ hollar, payer, ledgers, amount, payerBalance, mint }: {
  hollar: string; payer: string; ledgers: { address: string; held: BigNumberish }[]; amount: BigNumberish;
  payerBalance: BigNumberish; mint?: { capacity: BigNumberish; level: BigNumberish };
}): Call[] {
  const target = BigNumber.from(amount);
  if (target.lte(0)) throw new Error("reserve amount must be positive");
  const short = ledgers.map(l => ({ ...l, need: target.sub(l.held) })).filter(l => l.need.gt(0));
  const total = short.reduce((a, l) => a.add(l.need), BigNumber.from(0));
  if (total.isZero()) return [];
  const calls: Call[] = [];
  if (mint) {
    const room = BigNumber.from(mint.capacity).sub(mint.level);
    if (room.lt(total)) throw new Error(`facilitator room ${room} is short of ${total}`);
    calls.push({ to: hollar, data: tokenI.encodeFunctionData("mint", [payer, total]), label: `HOLLAR.mint(${payer}, ${total})` });
  } else if (BigNumber.from(payerBalance).lt(total)) {
    throw new Error(`prefund ${payer} with ${total} HOLLAR wei for the protocol reserves`);
  }
  for (const l of short) {
    calls.push({ to: hollar, data: tokenI.encodeFunctionData("approve", [l.address, l.need]), label: `HOLLAR.approve(${l.address}, ${l.need})` });
    calls.push({ to: l.address, data: ledgerI.encodeFunctionData("fundReserve", [l.need]), label: `mainDebt ${l.address}.fundReserve(${l.need})` });
  }
  return calls;
}

/// readiness: only what `e` names is checked, so an older deployment keeps its table
export function nextChecks(state: NextState, e: Expected): Check[] {
  const out: Check[] = [];
  const loop = state.subLoop;
  for (const k of e.keepers ?? []) {
    out.push({ name: `${k}: SubLoop KEEPER_ROLE (quoted pokes)`, ok: loop.keepers[k]?.keeper === true });
    for (const v of state.vaults) {
      const r = v.keepers[k] ?? {};
      out.push({ name: `${v.address}: ${k} has DEPOSIT_GUARDIAN_ROLE (setDeficitStop)`, ok: r.keeper === true });
      out.push({ name: `${v.address}: ${k} cannot pause or administer`, ok: r.guardian === false && r.admin === false });
    }
  }
  if (e.harvestThreshold !== undefined) {
    out.push({ name: "harvest threshold", ok: loop.harvestThreshold.eq(e.harvestThreshold), detail: loop.harvestThreshold.toString() });
  }
  if (e.intentTtl !== undefined || e.intentDriftBps !== undefined) {
    out.push({ name: "intent ttl (seconds)", ok: e.intentTtl === undefined || loop.intentTtl === e.intentTtl, detail: String(loop.intentTtl) });
    out.push({ name: "intent drift (bps)", ok: e.intentDriftBps === undefined || loop.intentDriftBps === e.intentDriftBps, detail: String(loop.intentDriftBps) });
    for (const l of state.controller?.lanes ?? [{ name: "entry" }, { name: "unwind" }] as any[]) {
      out.push({ name: `loop ${l.name} lane is async`, ok: l.async === true, detail: l.lane });
    }
  }
  if (e.band !== undefined) {
    for (const v of state.vaults) {
      const live = v.gaps && v.maxLtv !== undefined
        ? { relever: v.maxLtv - v.gaps.target - v.gaps.relever, target: v.maxLtv - v.gaps.target, delever: v.maxLtv - v.gaps.target + v.gaps.delever }
        : undefined;
      out.push({ name: `${v.address}: rebalance band ${showBand(e.band)}`, ok: !!live && sameBand(live, e.band),
        detail: live ? `${showBand(live)} under max ${v.maxLtv}` : "unreadable" });
    }
  }
  if (e.admissionMaxDeficitBps !== undefined) {
    out.push({ name: "deposit admission deficit cap (bps)", ok: loop.admissionMaxDeficitBps === e.admissionMaxDeficitBps, detail: String(loop.admissionMaxDeficitBps) });
  }
  if (e.exitHeadroom !== undefined) {
    const h = e.exitHeadroom;
    for (const v of state.vaults) {
      out.push({ name: `${v.address}: headroom exits ${showHeadroom(h)}`,
        ok: !!v.exitHeadroom && v.exitHeadroom.enabled === h.enabled && v.exitHeadroom.gapBps === h.gapBps,
        detail: v.exitHeadroom ? showHeadroom(v.exitHeadroom) : "unreadable" });
    }
  }
  if (e.reserve !== undefined) {
    for (const v of state.vaults) {
      out.push({ name: `${v.mainDebt}: protocol reserve`, ok: !!v.protocolReserve && v.protocolReserve.gte(e.reserve), detail: String(v.protocolReserve) });
    }
  }
  return out;
}

// ── the launch referendum's own parts: execution policy, discount install, funding, bootstrap ──
// mainnet sizes, from lark 4's working release candidate without its lark-only price approvals
export const LAUNCH = {
  pacing: 60,
  expiryDays: 90,
  // HOLLAR 18dp in, aPRIME 6dp out and back: 2,500 a trade, 25,000 deep, 50 a second
  entry: { capacity: utils.parseUnits("25000", 18), refill: utils.parseUnits("50", 18), minimum: utils.parseUnits("1", 18), maximum: utils.parseUnits("2500", 18) },
  unwind: { capacity: utils.parseUnits("25000", 6), refill: utils.parseUnits("50", 6), minimum: BigNumber.from(10000), maximum: utils.parseUnits("2500", 6) },
  // PRIME 6dp, one budget for every vault's harvest
  harvest: { capacity: utils.parseUnits("1000", 6), refill: utils.parseUnits("1", 6), minimum: BigNumber.from(10000), maximum: utils.parseUnits("50", 6) },
  // collateral sold for Main interest, by asset id: tBTC and GIGAETH (18dp), ~$100 a trade
  service: {
    1000765: { capacity: utils.parseUnits("0.1", 18), refill: BigNumber.from(10).pow(14), minimum: BigNumber.from(10).pow(10), maximum: BigNumber.from(10).pow(15) },
    4200: { capacity: utils.parseUnits("1", 18), refill: BigNumber.from(10).pow(15), minimum: BigNumber.from(10).pow(12), maximum: utils.parseUnits("0.02", 18) },
  } as Record<number, Size>,
  // the vault's compound floor and its harvest and servicing lanes
  collateralShortfallBps: 100,
  // the bootstrap deposit governance makes; the first public one would revert without it
  bootstrap: "0.0001",
  // the loop's lazy-executor callbacks pay in WETH: ~1.5e12 wei each, HDX keeps the fee currency from moving
  iceWeth: BigNumber.from(10).pow(16),
  iceHdx: BigNumber.from(10).pow(13),
  // the discounted HOLLAR notional of the loop's debt
  loopCap: utils.parseUnits("5000000", 18),
};
export type Size = { capacity: BigNumberish; refill: BigNumberish; minimum: BigNumberish; maximum: BigNumberish };
export type PolicySpec = { expiresAt: number; pacing: number; primeShortfallBps: number; collateralShortfallBps: number;
  entry: Size; unwind: Size; harvest: Size; service: Record<number, Size> };
export type Policy = {
  maxQuoteAge: number; maxQuoteBlocks: number;
  budgets: { name: string; group: string; token: string; capacity: string; refillPerSecond: string; expiresAt: number; minIntervalSeconds: number }[];
  limits: { name: string; consumer: string; input: string; output: string; lane: string; group: string; minimum: string; maximum: string; maxShortfallBps: number; safety: boolean }[];
  actions: { target: string; signature: string }[];
  bound: string[];
};
export type LaunchVault = { address: string; mainDebt: string; collateral: string; assetId: number; key: string };
export const groupId = (name: string) => utils.keccak256(utils.toUtf8Bytes(`juicer-${name}`));
export const laneId = (consumer: string, input: string, output: string) =>
  utils.keccak256(utils.defaultAbiCoder.encode(["address", "address", "address"], [consumer, input, output]));

const controlAllI = new utils.Interface([
  "function configureBudget(bytes32,address,uint128,uint128,uint64)", "function configurePacing(bytes32,uint64)",
  "function configureLimit(address,address,address,bytes32,uint128,uint128)", "function configurePrice(bytes32,uint16,bool)",
  "function configureAction(address,bytes4,bool)",
]);
const bindI = new utils.Interface(["function setExecutionController(address)"]);

/// budgets, lanes, prices and quote entrypoints as verify-readiness reads them (JUICER_EXECUTION_POLICY)
export function executionPolicy(a: { subLoop: string; harvester: string; hollar: string; prime: string; aPrime: string; vaults: LaunchVault[] },
  spec: PolicySpec, quotes = { age: 60, blocks: 5 }): Policy {
  for (const bps of [spec.primeShortfallBps, spec.collateralShortfallBps]) {
    if (!(Number.isInteger(bps) && bps >= 0 && bps < 10000)) throw new Error(`shortfall ${bps} bps out of range`);
  }
  const budgets: Policy["budgets"] = [], limits: Policy["limits"] = [];
  const budget = (name: string, token: string, s: Size) => budgets.push({ name, group: groupId(name), token,
    capacity: BigNumber.from(s.capacity).toString(), refillPerSecond: BigNumber.from(s.refill).toString(), expiresAt: spec.expiresAt, minIntervalSeconds: spec.pacing });
  const limit = (name: string, group: string, consumer: string, input: string, output: string, s: Size, maxShortfallBps: number, safety = false) => {
    if (BigNumber.from(s.minimum).lte(0) || BigNumber.from(s.maximum).lt(s.minimum) || BigNumber.from(s.maximum).gt(s.capacity)) {
      throw new Error(`${name}: lane sizes need 0 < minimum <= maximum <= capacity`);
    }
    limits.push({ name, consumer, input, output, lane: laneId(consumer, input, output), group: groupId(group),
      minimum: BigNumber.from(s.minimum).toString(), maximum: BigNumber.from(s.maximum).toString(), maxShortfallBps, safety });
  };
  budget("entry", a.hollar, spec.entry);
  budget("unwind", a.aPrime, spec.unwind);
  budget("harvest", a.prime, spec.harvest);
  limit("entry", "entry", a.subLoop, a.hollar, a.aPrime, spec.entry, spec.primeShortfallBps);
  // only the source's repayment may bypass expiry and pacing
  limit("unwind", "unwind", a.subLoop, a.aPrime, a.hollar, spec.unwind, spec.primeShortfallBps, true);
  for (const v of a.vaults) {
    const service = spec.service[v.assetId];
    if (!service) throw new Error(`no servicing lane size for collateral ${v.assetId}`);
    budget(`service-${v.key}`, v.collateral, service);
    limit(`harvest-${v.key}`, "harvest", v.address, a.prime, v.collateral, spec.harvest, spec.collateralShortfallBps);
    limit(`service-${v.key}`, `service-${v.key}`, v.address, v.collateral, a.hollar, service, spec.collateralShortfallBps);
    limit(`service-ledger-${v.key}`, `service-${v.key}`, v.mainDebt, v.collateral, a.hollar, service, spec.collateralShortfallBps);
  }
  const actions = [{ target: a.subLoop, signature: "pokeBorrow()" }, { target: a.subLoop, signature: "pokeRepay()" },
    { target: a.harvester, signature: "harvest(uint256[])" }, ...a.vaults.map(v => ({ target: v.address, signature: "rebalance()" }))];
  return { maxQuoteAge: quotes.age, maxQuoteBlocks: quotes.blocks, budgets, limits, actions, bound: [a.subLoop, a.harvester, ...a.vaults.map(v => v.address)] };
}

export type ExecutionState = {
  controller: string;
  budgets: Record<string, { token: string; capacity: BigNumber; refill: BigNumber; expiresAt: number; interval: number }>;
  limits: Record<string, { group: string; minimum: BigNumber; maximum: BigNumber; shortfall: number; safety: boolean }>;
  actions: Record<string, boolean>;
  bound: Record<string, string>;
};
const selector = (signature: string) => utils.id(signature).slice(0, 10);
const actionKey = (target: string, signature: string) => `${target.toLowerCase()}:${signature}`;

export async function readExecution(provider: any, controller: string, p: Policy): Promise<ExecutionState> {
  const c = new Contract(controller, [
    "function budgets(bytes32) view returns (address token,uint128 capacity,uint128 refillPerSecond,uint128 credit,uint64 updatedAt,uint64 expiresAt)",
    "function pacing(bytes32) view returns (uint64 interval,uint64 nextAt,uint256 lastBlock)",
    "function limits(bytes32) view returns (bytes32 group,uint128 minimum,uint128 maximum)",
    "function maxShortfallBps(bytes32) view returns (uint16)", "function safetyLanes(bytes32) view returns (bool)",
    "function actions(address,bytes4) view returns (bool)",
  ], provider);
  const s: ExecutionState = { controller, budgets: {}, limits: {}, actions: {}, bound: {} };
  for (const b of p.budgets) {
    const x = await c.budgets(b.group);
    s.budgets[b.group] = { token: x.token, capacity: x.capacity, refill: x.refillPerSecond, expiresAt: Number(x.expiresAt), interval: Number((await c.pacing(b.group)).interval) };
  }
  for (const l of p.limits) {
    const x = await c.limits(l.lane);
    s.limits[l.lane] = { group: x.group, minimum: x.minimum, maximum: x.maximum, shortfall: Number(await c.maxShortfallBps(l.lane)), safety: await c.safetyLanes(l.lane) };
  }
  for (const a of p.actions) s.actions[actionKey(a.target, a.signature)] = await c.actions(a.target, selector(a.signature));
  for (const t of p.bound) s.bound[t.toLowerCase()] = await new Contract(t, ["function executionController() view returns (address)"], provider).executionController();
  return s;
}

/// what the controller still lacks, in the order it accepts them: budgets, lanes, prices, entrypoints, bindings
export function executionCalls(s: ExecutionState, p: Policy): Call[] {
  const calls: Call[] = [], same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  for (const b of p.budgets) {
    const x = s.budgets[b.group];
    if (x.token !== constants.AddressZero && !same(x.token, b.token)) throw new Error(`budget ${b.name} holds ${x.token}, not ${b.token}`);
    if (!same(x.token, b.token) || !x.capacity.eq(b.capacity) || !x.refill.eq(b.refillPerSecond) || x.expiresAt !== b.expiresAt) {
      calls.push({ to: s.controller, data: controlAllI.encodeFunctionData("configureBudget", [b.group, b.token, b.capacity, b.refillPerSecond, b.expiresAt]),
        label: `controller.configureBudget(${b.name}, ${b.capacity} cap, ${b.refillPerSecond}/s, until ${b.expiresAt})` });
    }
    if (x.interval !== b.minIntervalSeconds) {
      calls.push({ to: s.controller, data: controlAllI.encodeFunctionData("configurePacing", [b.group, b.minIntervalSeconds]), label: `controller.configurePacing(${b.name}, ${b.minIntervalSeconds} s)` });
    }
  }
  for (const l of p.limits) {
    const x = s.limits[l.lane];
    if (x.group.toLowerCase() !== l.group.toLowerCase() || !x.minimum.eq(l.minimum) || !x.maximum.eq(l.maximum)) {
      calls.push({ to: s.controller, data: controlAllI.encodeFunctionData("configureLimit", [l.consumer, l.input, l.output, l.group, l.minimum, l.maximum]),
        label: `controller.configureLimit(${l.name}, ${l.minimum}..${l.maximum})` });
    }
  }
  for (const l of p.limits) {
    const x = s.limits[l.lane];
    if (x.shortfall !== l.maxShortfallBps || x.safety !== l.safety) {
      calls.push({ to: s.controller, data: controlAllI.encodeFunctionData("configurePrice", [l.lane, l.maxShortfallBps, l.safety]),
        label: `controller.configurePrice(${l.name}, ${l.maxShortfallBps} bps${l.safety ? ", safety" : ""})` });
    }
  }
  for (const a of p.actions) {
    if (!s.actions[actionKey(a.target, a.signature)]) {
      calls.push({ to: s.controller, data: controlAllI.encodeFunctionData("configureAction", [a.target, selector(a.signature), true]), label: `controller.configureAction(${a.target}, ${a.signature})` });
    }
  }
  for (const t of p.bound) {
    const bound = s.bound[t.toLowerCase()];
    if (bound === constants.AddressZero) calls.push({ to: t, data: bindI.encodeFunctionData("setExecutionController", [s.controller]), label: `${t}.setExecutionController(${s.controller})` });
    else if (!same(bound, s.controller)) throw new Error(`${t} is bound to another controller, ${bound}`);
  }
  return calls;
}

export type DiscountState = { code: boolean; token: string; strategy: string; vaults: { address: string; controller: string; registered: boolean }[]; loop: string; loopCap: BigNumber };
const debtI = new utils.Interface(["function updateDiscountToken(address)", "function updateDiscountRateStrategy(address)"]);
const enrollI = new utils.Interface(["function registerVault(address)", "function registerLoop(address,uint256)", "function setLoopCap(uint256)", "function setDiscountController(address)"]);

export async function readDiscount(provider: any, { discount, debtToken, vaults }: { discount: string; debtToken: string; vaults: string[] }): Promise<DiscountState> {
  const code = (await provider.getCode(discount)) !== "0x";
  const debt = new Contract(debtToken, ["function getDiscountToken() view returns (address)", "function getDiscountRateStrategy() view returns (address)"], provider);
  const d = new Contract(discount, ["function isRegistered(address) view returns (bool)", "function loop() view returns (address)", "function loopCap() view returns (uint256)"], provider);
  return {
    code, token: await debt.getDiscountToken(), strategy: await debt.getDiscountRateStrategy(),
    vaults: await Promise.all(vaults.map(async address => ({ address,
      controller: await new Contract(address, ["function discountController() view returns (address)"], provider).discountController(),
      registered: code ? await d.isRegistered(address) : false }))),
    loop: code ? await d.loop() : constants.AddressZero, loopCap: code ? await d.loopCap() : BigNumber.from(0),
  };
}

/// installed on the HOLLAR debt token, the vaults enrolled, then the loop: registerLoop needs a vault it funds
export function discountCalls(s: DiscountState, p: { discount: string; debtToken: string; subLoop: string; loopCap: BigNumberish }): Call[] {
  const calls: Call[] = [], same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  if (!s.code) throw new Error(`no JuicerDiscount at ${p.discount}: the deploy creates it`);
  if (!same(s.token, p.discount)) calls.push({ to: p.debtToken, data: debtI.encodeFunctionData("updateDiscountToken", [p.discount]), label: `hollarDebt.updateDiscountToken(${p.discount})`, gas: 1_000_000 });
  if (!same(s.strategy, p.discount)) calls.push({ to: p.debtToken, data: debtI.encodeFunctionData("updateDiscountRateStrategy", [p.discount]), label: `hollarDebt.updateDiscountRateStrategy(${p.discount})`, gas: 1_000_000 });
  for (const v of s.vaults) {
    if (!same(v.controller, p.discount)) calls.push({ to: v.address, data: enrollI.encodeFunctionData("setDiscountController", [p.discount]), label: `vault ${v.address}.setDiscountController(${p.discount})`, gas: 700_000 });
    if (!v.registered) calls.push({ to: p.discount, data: enrollI.encodeFunctionData("registerVault", [v.address]), label: `discount.registerVault(${v.address})`, gas: 700_000 });
  }
  const cap = BigNumber.from(p.loopCap);
  if (s.loop === constants.AddressZero) {
    calls.push({ to: p.discount, data: enrollI.encodeFunctionData("registerLoop", [p.subLoop, cap]), label: `discount.registerLoop(${p.subLoop}, ${utils.formatUnits(cap, 18)} HOLLAR)`, gas: 700_000 });
  } else if (!same(s.loop, p.subLoop)) {
    throw new Error(`the discount enrolls another loop, ${s.loop}`);
  } else if (!s.loopCap.eq(cap)) {
    calls.push({ to: p.discount, data: enrollI.encodeFunctionData("setLoopCap", [cap]), label: `discount.setLoopCap(${utils.formatUnits(cap, 18)} HOLLAR)`, gas: 700_000 });
  }
  return calls;
}

/// what the launch's earlier calls leave behind, for planning the later ones in the same referendum
export function assumePlanned(state: NextState, p: { policy?: Policy; discount?: { address: string; loop: string }; feeBps?: number }): NextState {
  const next: NextState = JSON.parse(JSON.stringify(state), (k, v) => v && v.type === "BigNumber" ? BigNumber.from(v.hex) : v);
  if (p.policy && next.controller) {
    for (const l of next.controller.lanes) {
      const planned = p.policy.limits.find(x => x.lane.toLowerCase() === l.lane.toLowerCase());
      if (l.maximum.isZero() && planned) l.maximum = BigNumber.from(planned.maximum);
    }
  }
  if (p.discount) {
    const d = next.discount;
    next.discount = { address: p.discount.address, installed: true, discountBps: d?.discountBps ?? 0, loopDiscountBps: d?.loopDiscountBps ?? 0,
      loop: d?.loop && d.loop !== constants.AddressZero ? d.loop : p.discount.loop };
  }
  if (p.feeBps !== undefined) for (const v of next.vaults) v.protocolFeeBps ??= p.feeBps;
  return next;
}

const vaultI = new utils.Interface(["function unpauseDeposits()", "function deposit(uint256,address)", "function fundRoundingReserve(uint256)"]);

/// governance's locked first deposit: deposits stay closed to the public until it lands, so it goes last
export function bootstrapCalls({ vault, asset, seed, receiver, supply, paused }:
  { vault: string; asset: string; seed: BigNumberish; receiver: string; supply: BigNumberish; paused: boolean }): Call[] {
  if (!BigNumber.from(supply).isZero()) return [];
  if (BigNumber.from(seed).lte(1000)) throw new Error(`bootstrap ${seed} must exceed the 1,000 dead shares`);
  return [
    ...(paused ? [{ to: vault, data: vaultI.encodeFunctionData("unpauseDeposits"), label: `vault ${vault}.unpauseDeposits()` }] : []),
    { to: asset, data: tokenI.encodeFunctionData("approve", [vault, seed]), label: `collateral.approve(${vault}, ${seed})` },
    { to: vault, data: vaultI.encodeFunctionData("deposit", [seed, receiver]), label: `vault ${vault}.deposit(${seed}, ${receiver})`, gas: 3_000_000 },
    { to: asset, data: tokenI.encodeFunctionData("approve", [vault, 0]), label: `collateral.approve(${vault}, 0)` },
  ];
}
