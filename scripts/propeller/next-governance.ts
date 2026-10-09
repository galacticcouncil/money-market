// The next version's governance surface, shared by the mainnet proposal and the readiness
// checker: keeper roles, the harvest threshold, ICE and the protocol reserve. One reader,
// then pure planning: callers get back only the calls still missing, or the checks.
import { BigNumber, BigNumberish, Contract, utils } from "ethers";

export const NEXT = {
  // ~0.02% of principal per harvest
  harvestThreshold: BigNumber.from("200000000000000"),
  // seconds: the loop sets each deadline to (block.timestamp + ttl) * 1000 ms, under a day
  intentTtl: 300,
  // keeper-quote tolerance beside the solver's 1 bp haircut
  intentDriftBps: 2,
  reserveHollar: "1000",
};
export const KEEPER_ROLE = utils.id("KEEPER_ROLE");
export const DEPOSIT_GUARDIAN_ROLE = utils.id("DEPOSIT_GUARDIAN_ROLE");
export const GUARDIAN_ROLE = utils.id("GUARDIAN_ROLE");
export const ADMIN_ROLE = utils.id("ADMIN_ROLE");

const access = new utils.Interface(["function grantRole(bytes32,address)"]);
const loopI = new utils.Interface([
  "function setParams(uint256,uint256,uint256,uint256)",
  "function configureIntents(uint32,uint16)",
]);
const controlI = new utils.Interface(["function configureAsync(bytes32,bool)"]);
const tokenI = new utils.Interface(["function approve(address,uint256) returns (bool)", "function mint(address,uint256)"]);
const ledgerI = new utils.Interface(["function fundReserve(uint256)"]);

export type Call = { to: string; data: string; label: string };
export type Check = { name: string; ok: boolean; detail?: string };
type Roles = Record<string, { keeper?: boolean; guardian?: boolean; admin?: boolean }>;
export type NextState = {
  subLoop: {
    address: string;
    targetHf: BigNumber; deployHfFloor: BigNumber; deLeverTrigger: BigNumber; harvestThreshold: BigNumber;
    // undefined: contracts without that part of the surface
    intentTtl?: number; intentDriftBps?: number; keeperRole?: string; keepers: Roles;
  };
  vaults: { address: string; guardianRole?: string; keepers: Roles; mainDebt: string; protocolReserve?: BigNumber }[];
  controller?: { address: string; lanes: { name: string; lane: string; maximum: BigNumber; async?: boolean }[] };
};
export type Expected = {
  keepers?: string[]; harvestThreshold?: BigNumberish; intentTtl?: number; intentDriftBps?: number; reserve?: BigNumberish;
};

async function maybe<T>(fn: () => Promise<T>): Promise<T | undefined> {
  try {
    return await fn();
  } catch {
    return undefined;
  }
}

export async function readNextState(provider: any, { subLoop, vaults, controller, keepers }:
  { subLoop: string; vaults: string[]; controller?: string; keepers: string[] }): Promise<NextState> {
  const loop = new Contract(subLoop, [
    "function targetHf() view returns (uint256)", "function deployHfFloor() view returns (uint256)",
    "function deLeverTrigger() view returns (uint256)", "function harvestThreshold() view returns (uint256)",
    "function intentTtl() view returns (uint32)", "function intentDriftBps() view returns (uint16)",
    "function KEEPER_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)",
    "function hollar() view returns (address)", "function primeAToken() view returns (address)",
  ], provider);
  const keeperRole = await maybe(() => loop.KEEPER_ROLE());
  const ttl = await maybe(() => loop.intentTtl()), drift = await maybe(() => loop.intentDriftBps());
  const state: NextState = {
    subLoop: {
      address: subLoop,
      targetHf: await loop.targetHf(), deployHfFloor: await loop.deployHfFloor(),
      deLeverTrigger: await loop.deLeverTrigger(), harvestThreshold: await loop.harvestThreshold(),
      intentTtl: ttl === undefined ? undefined : Number(ttl), intentDriftBps: drift === undefined ? undefined : Number(drift),
      keeperRole, keepers: {},
    },
    vaults: [],
  };
  for (const k of keepers) state.subLoop.keepers[k] = { keeper: keeperRole ? await loop.hasRole(keeperRole, k) : undefined };
  for (const address of vaults) {
    const v = new Contract(address, [
      "function DEPOSIT_GUARDIAN_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)",
      "function mainDebt() view returns (address)",
    ], provider);
    const guardianRole = await maybe(() => v.DEPOSIT_GUARDIAN_ROLE());
    const mainDebt = await v.mainDebt();
    const row = { address, guardianRole, keepers: {} as Roles, mainDebt,
      protocolReserve: await maybe(() => new Contract(mainDebt, ["function protocolReserve() view returns (uint256)"], provider).protocolReserve()) };
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
}

const missingSurface = (what: string) => new Error(`${what} missing on chain: these are not the next version's contracts`);

/// keeper roles, the threshold and ICE; the Main and vault wiring stays in the existing batches
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
    if (!state.controller) throw new Error("ICE needs the execution controller (PROPELLER_EXECUTION_CONTROLLER)");
    for (const l of state.controller.lanes) {
      if (l.async === undefined) throw missingSurface("ExecutionController async lanes");
      if (l.maximum.isZero()) throw new Error(`the loop's ${l.name} lane has no limit: configure the execution lanes first`);
      if (!l.async) calls.push({ to: state.controller.address, data: controlI.encodeFunctionData("configureAsync", [l.lane, true]), label: `controller.configureAsync(${l.name} ${l.lane}, true)` });
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
  if (e.reserve !== undefined) {
    for (const v of state.vaults) {
      out.push({ name: `${v.mainDebt}: protocol reserve`, ok: !!v.protocolReserve && v.protocolReserve.gte(e.reserve), detail: String(v.protocolReserve) });
    }
  }
  return out;
}
