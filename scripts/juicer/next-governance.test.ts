import assert from "node:assert/strict";
import { test } from "node:test";
import { BigNumber, providers, utils } from "ethers";
import { NEXT, KEEPER_ROLE, DEPOSIT_GUARDIAN_ROLE, GUARDIAN_ROLE, readNextState, nextCalls, reserveCalls, nextChecks } from "./next-governance";

const addr = (n: number) => utils.getAddress(`0x${n.toString(16).padStart(40, "0")}`);
const LOOP = addr(0x10), H = addr(0x11), A = addr(0x12), C = addr(0x13), V1 = addr(0x21), V2 = addr(0x22), M1 = addr(0x31), M2 = addr(0x32);
const K1 = addr(0x41), K2 = addr(0x42);
const lane = (c: string, i: string, o: string) => utils.keccak256(utils.defaultAbiCoder.encode(["address", "address", "address"], [c, i, o]));
const ENTRY = lane(LOOP, H, A), EXIT = lane(LOOP, A, H);
const coder = utils.defaultAbiCoder;

// a chain answering eth_call from a table of (address, signature) handlers; anything else reverts
class Chain extends providers.StaticJsonRpcProvider {
  constructor(private fns: Record<string, Record<string, (args: utils.Result) => [string[], any[]]>>) { super("http://stub.invalid", 222222); }
  async send(method: string, params: any[]): Promise<any> {
    if (method === "eth_chainId") return "0x3640e";
    if (method !== "eth_call") throw new Error(`unexpected ${method}`);
    const { to, data } = params[0];
    for (const [signature, fn] of Object.entries(this.fns[utils.getAddress(to)] ?? {})) {
      const fragment = utils.FunctionFragment.from(signature);
      if (data.slice(0, 10) !== utils.Interface.getSighash(fragment)) continue;
      const [types, values] = fn(coder.decode(fragment.inputs, "0x" + data.slice(10)));
      return coder.encode(types, values);
    }
    throw new Error("execution reverted");
  }
}
const v = (type: string, value: any) => () => [[type], [value]] as [string[], any[]];
function nextChain({ granted = new Set<string>(), ttl = 0, drift = 0, async = false, threshold = "1000000000000000", reserve = "0", old = false } = {}) {
  const has = (role: string, who: string) => granted.has(`${role}:${who}`);
  const roles = (extra: Record<string, any>) => ({ "hasRole(bytes32,address)": (a: utils.Result) => [["bool"], [has(a[0], a[1])]] as [string[], any[]], ...extra });
  return new Chain({
    [LOOP]: roles({
      "targetHf()": v("uint256", "1050000000000000000"), "deployHfFloor()": v("uint256", "1050000000000000000"),
      "deLeverTrigger()": v("uint256", "1100000000000000000"), "harvestThreshold()": v("uint256", threshold),
      "hollar()": v("address", H), "primeAToken()": v("address", A),
      ...(old ? {} : { "intentTtl()": v("uint32", ttl), "intentDriftBps()": v("uint16", drift), "KEEPER_ROLE()": v("bytes32", KEEPER_ROLE) }),
    }),
    ...Object.fromEntries([[V1, M1], [V2, M2]].map(([vault, ledger]) => [vault, roles({
      "mainDebt()": v("address", ledger), ...(old ? {} : { "DEPOSIT_GUARDIAN_ROLE()": v("bytes32", DEPOSIT_GUARDIAN_ROLE) }),
    })])),
    ...(old ? {} : { [M1]: { "protocolReserve()": v("uint256", reserve) }, [M2]: { "protocolReserve()": v("uint256", reserve) } }),
    [C]: {
      "lane(address,address,address)": (a: utils.Result) => [["bytes32"], [lane(a[0], a[1], a[2])]],
      "limits(bytes32)": (a: utils.Result) => [["bytes32", "uint128", "uint128"], [utils.hexZeroPad("0x01", 32), 1, a[0] === ENTRY ? utils.parseUnits("2500", 18) : utils.parseUnits("2500", 6)]],
      ...(old ? {} : { "asyncLanes(bytes32)": v("bool", async) }),
    },
  });
}
const read = (chain: Chain) => readNextState(chain, { subLoop: LOOP, vaults: [V1, V2], controller: C, keepers: [K1, K2] });
const expected = { keepers: [K1, K2], harvestThreshold: NEXT.harvestThreshold, intentTtl: NEXT.intentTtl, intentDriftBps: NEXT.intentDriftBps };
const decode = (signature: string, data: string) => new utils.Interface([`function ${signature}`]).decodeFunctionData(signature.split("(")[0], data);

test("a fresh next-version deployment gets keeper roles, the threshold and ICE, and nothing else", async () => {
  const calls = nextCalls(await read(nextChain()), expected);
  assert.deepEqual(calls.map(c => c.label.split("(")[0]), [
    "subLoop.grantRole", "subLoop.grantRole",
    `vault ${V1}.grantRole`, `vault ${V1}.grantRole`, `vault ${V2}.grantRole`, `vault ${V2}.grantRole`,
    "subLoop.setParams", "subLoop.configureIntents", "controller.configureAsync", "controller.configureAsync",
  ]);
  assert.deepEqual(decode("grantRole(bytes32,address)", calls[0].data).map(String), [KEEPER_ROLE, K1]);
  assert.deepEqual(decode("grantRole(bytes32,address)", calls[2].data).map(String), [DEPOSIT_GUARDIAN_ROLE, K1]);
  assert.ok(calls.every(c => !c.data.includes(GUARDIAN_ROLE.slice(2))), "keepers never get the pause");
  const params = decode("setParams(uint256,uint256,uint256,uint256)", calls[6].data).map(String);
  assert.deepEqual(params, ["1050000000000000000", "1050000000000000000", "1100000000000000000", "200000000000000"], "only the threshold changes");
  assert.deepEqual(decode("configureIntents(uint32,uint16)", calls[7].data).map(Number), [300, 2]);
  assert.deepEqual(calls.slice(8).map(c => decode("configureAsync(bytes32,bool)", c.data)[0]), [ENTRY, EXIT]);
  assert.deepEqual(calls.map(c => c.to), [LOOP, LOOP, V1, V1, V2, V2, LOOP, LOOP, C, C]);
});

test("a wired deployment needs no calls and passes every check", async () => {
  const granted = new Set([K1, K2].flatMap(k => [`${KEEPER_ROLE}:${k}`, `${DEPOSIT_GUARDIAN_ROLE}:${k}`]));
  const state = await read(nextChain({ granted, ttl: 300, drift: 2, async: true, threshold: "200000000000000", reserve: utils.parseUnits("1000", 18).toString() }));
  assert.deepEqual(nextCalls(state, expected), []);
  const checks = nextChecks(state, { ...expected, reserve: utils.parseUnits("1000", 18) });
  assert.equal(checks.length, 2 + 2 * 4 + 1 + 4 + 2);
  assert.ok(checks.every(c => c.ok), JSON.stringify(checks.filter(c => !c.ok)));
});

test("readiness catches a missing grant, a keeper that can pause, a short reserve", async () => {
  const granted = new Set([`${KEEPER_ROLE}:${K1}`, `${DEPOSIT_GUARDIAN_ROLE}:${K1}`, `${GUARDIAN_ROLE}:${K1}`]);
  const failed = nextChecks(await read(nextChain({ granted, ttl: 300, drift: 2, async: true })), { keepers: [K1, K2], reserve: 1 })
    .filter(c => !c.ok).map(c => c.name);
  assert.ok(failed.includes(`${K2}: SubLoop KEEPER_ROLE (quoted pokes)`));
  assert.ok(failed.includes(`${V1}: ${K1} cannot pause or administer`));
  assert.ok(failed.includes(`${M1}: protocol reserve`));
  assert.deepEqual(nextChecks(await read(nextChain()), {}), [], "an older deployment's table is unchanged");
});

test("the surface is read, not assumed: old contracts refuse the next-version calls", async () => {
  const state = await read(nextChain({ old: true }));
  assert.equal(state.subLoop.keeperRole, undefined);
  assert.equal(state.subLoop.intentTtl, undefined);
  assert.equal(state.controller!.lanes[0].async, undefined);
  assert.throws(() => nextCalls(state, { keepers: [K1] }), /KEEPER_ROLE missing on chain/);
  assert.throws(() => nextCalls(state, { intentTtl: 300 }), /intents missing on chain/);
  assert.deepEqual(nextCalls(state, { harvestThreshold: NEXT.harvestThreshold }).map(c => c.label.split("(")[0]), ["subLoop.setParams"]);
});

test("intent ttl is seconds under a day, and ICE needs configured lanes", async () => {
  const state = await read(nextChain());
  for (const intentTtl of [0, 86400, 300000]) assert.throws(() => nextCalls(state, { intentTtl }), /seconds/);
  assert.throws(() => nextCalls(state, { intentDriftBps: 9999 }), /drift/);
  assert.throws(() => nextCalls(state, { harvestThreshold: utils.parseUnits("1", 18) }), /WAD fraction/);
  state.controller!.lanes[1].maximum = BigNumber.from(0);
  assert.throws(() => nextCalls(state, { intentTtl: 300 }), /unwind lane has no limit/);
  assert.throws(() => nextCalls({ ...state, controller: undefined }, { intentTtl: 300 }), /JUICER_EXECUTION_CONTROLLER/);
});

test("the protocol reserve comes from the governance caller's HOLLAR or its facilitator", () => {
  const ledgers = [{ address: M1, held: 0 }, { address: M2, held: utils.parseUnits("400", 18) }];
  const amount = utils.parseUnits("1000", 18), need = utils.parseUnits("1600", 18);
  const admin = addr(0xaa);
  const funded = reserveCalls({ hollar: H, payer: admin, ledgers, amount, payerBalance: need });
  assert.deepEqual(funded.map(c => c.label.split("(")[0]), ["HOLLAR.approve", `mainDebt ${M1}.fundReserve`, "HOLLAR.approve", `mainDebt ${M2}.fundReserve`]);
  assert.equal(String(decode("fundReserve(uint256)", funded[3].data)[0]), utils.parseUnits("600", 18).toString());
  assert.throws(() => reserveCalls({ hollar: H, payer: admin, ledgers, amount, payerBalance: need.sub(1) }), /prefund/);
  const minted = reserveCalls({ hollar: H, payer: admin, ledgers, amount, payerBalance: 0, mint: { capacity: need, level: 0 } });
  assert.deepEqual(decode("mint(address,uint256)", minted[0].data).map(String), [admin, need.toString()]);
  assert.throws(() => reserveCalls({ hollar: H, payer: admin, ledgers, amount, payerBalance: 0, mint: { capacity: need, level: 1 } }), /facilitator room/);
  assert.deepEqual(reserveCalls({ hollar: H, payer: admin, ledgers: [{ address: M1, held: amount }], amount, payerBalance: 0 }), []);
});

test("mainnet and lark agree on the next-version parameters", async () => {
  const { ICE } = await import("./lark-ice-plan.mjs");
  const { NEXT_PARAMS } = await import("./lark-pins.mjs");
  assert.deepEqual([ICE.ttl, ICE.driftBps], [NEXT.intentTtl, NEXT.intentDriftBps]);
  assert.equal(NEXT_PARAMS.harvestThreshold.toString(), NEXT.harvestThreshold.toString());
  assert.equal(NEXT_PARAMS.reserve.toString(), utils.parseUnits(NEXT.reserveHollar, 18).toString());
});
