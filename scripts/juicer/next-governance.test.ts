import assert from "node:assert/strict";
import { test } from "node:test";
import { BigNumber, providers, utils } from "ethers";
import {
  NEXT, envNumber, parseExitHeadroom, KEEPER_ROLE, DEPOSIT_GUARDIAN_ROLE, GUARDIAN_ROLE, readNextState, nextCalls, reserveCalls, nextChecks, bandGaps, parseBand,
} from "./next-governance";

const addr = (n: number) => utils.getAddress(`0x${n.toString(16).padStart(40, "0")}`);
const LOOP = addr(0x10), H = addr(0x11), A = addr(0x12), C = addr(0x13), V1 = addr(0x21), V2 = addr(0x22), M1 = addr(0x31), M2 = addr(0x32);
const K1 = addr(0x41), K2 = addr(0x42), P = addr(0x51), ETH = addr(0x61), BTC = addr(0x62);
const DISC = addr(0x71), DEBT = addr(0x72), FEES = addr(0x73), ZERO = utils.getAddress(addr(0));
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
function nextChain({ granted = new Set<string>(), ttl = 0, drift = 0, async = false, threshold = "1000000000000000", reserve = "0", old = false,
  gaps = {} as Record<string, number[]>, ltv = { [ETH]: 7500, [BTC]: 8000 } as Record<string, number>,
  installed = true, enrolled = true, main = 0, loopRate = 0 as number | null, fee = 500 as number | null, admission = 50 as number | null,
  headroom = [false, 0] as [boolean, number] | null } = {}) {
  const has = (role: string, who: string) => granted.has(`${role}:${who}`);
  const roles = (extra: Record<string, any>) => ({ "hasRole(bytes32,address)": (a: utils.Result) => [["bool"], [has(a[0], a[1])]] as [string[], any[]], ...extra });
  return new Chain({
    [LOOP]: roles({
      "targetHf()": v("uint256", "1050000000000000000"), "deployHfFloor()": v("uint256", "1050000000000000000"),
      "deLeverTrigger()": v("uint256", "1100000000000000000"), "harvestThreshold()": v("uint256", threshold),
      "hollar()": v("address", H), "primeAToken()": v("address", A), "pool()": v("address", P),
      ...(old ? {} : {
        "intentTtl()": v("uint32", ttl), "intentDriftBps()": v("uint16", drift), "KEEPER_ROLE()": v("bytes32", KEEPER_ROLE),
        "rebalanceBand(address)": (a: utils.Result) => [["uint16", "uint16", "uint16"], gaps[a[0]] ?? [0, 500, 300]],
        ...(admission === null ? {} : { "admissionMaxDeficitBps()": v("uint16", admission) }),
        ...(headroom === null ? {} : { "exitHeadroom(address)": () => [["bool", "uint16"], headroom] as [string[], any[]] }),
      }),
    }),
    ...Object.fromEntries([[V1, M1, ETH], [V2, M2, BTC]].map(([vault, ledger, collateral]) => [vault, roles({
      "mainDebt()": v("address", ledger), "collateral()": v("address", collateral),
      ...(old ? {} : { "DEPOSIT_GUARDIAN_ROLE()": v("bytes32", DEPOSIT_GUARDIAN_ROLE) }),
    })])),
    [P]: { "getConfiguration(address)": (a: utils.Result) => [["uint256"], [BigNumber.from(8500).shl(16).or(ltv[a[0]])]] },
    [DISC]: {
      "debtToken()": v("address", DEBT), "discountBps()": v("uint16", main),
      ...(loopRate === null ? {} : { "loopDiscountBps()": v("uint16", loopRate), "loop()": v("address", enrolled ? LOOP : ZERO) }),
    },
    [DEBT]: { "getDiscountToken()": v("address", installed ? DISC : ZERO), "getDiscountRateStrategy()": v("address", installed ? DISC : ZERO) },
    [FEES]: fee === null ? {} : { "protocolFeeBps(address)": v("uint16", fee) },
    ...(old ? {} : { [M1]: { "protocolReserve()": v("uint256", reserve) }, [M2]: { "protocolReserve()": v("uint256", reserve) } }),
    [C]: {
      "lane(address,address,address)": (a: utils.Result) => [["bytes32"], [lane(a[0], a[1], a[2])]],
      "limits(bytes32)": (a: utils.Result) => [["bytes32", "uint128", "uint128"], [utils.hexZeroPad("0x01", 32), 1, a[0] === ENTRY ? utils.parseUnits("2500", 18) : utils.parseUnits("2500", 6)]],
      ...(old ? {} : { "asyncLanes(bytes32)": v("bool", async) }),
    },
  });
}
const read = (chain: Chain) => readNextState(chain, { subLoop: LOOP, vaults: [V1, V2], controller: C, keepers: [K1, K2] });
const readAll = (chain: Chain) => readNextState(chain, { subLoop: LOOP, vaults: [V1, V2], controller: C, keepers: [K1, K2], discount: DISC, fees: FEES });
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
  const { NEXT_PARAMS, bandGaps: larkGaps } = await import("./lark-pins.mjs");
  assert.deepEqual([ICE.ttl, ICE.driftBps], [NEXT.intentTtl, NEXT.intentDriftBps]);
  assert.equal(NEXT_PARAMS.harvestThreshold.toString(), NEXT.harvestThreshold.toString());
  assert.equal(NEXT_PARAMS.reserve.toString(), utils.parseUnits(NEXT.reserveHollar, 18).toString());
  assert.deepEqual([NEXT_PARAMS.band, NEXT_PARAMS.revenue, NEXT_PARAMS.primePoolFeePpm, NEXT_PARAMS.admissionMaxDeficitBps, NEXT_PARAMS.exitHeadroom],
    [NEXT.band, NEXT.revenue, NEXT.primePoolFeePpm, NEXT.admissionMaxDeficitBps, NEXT.exitHeadroom]);
  for (const maxLtv of [7500, 8000, 8250]) assert.deepEqual(larkGaps(maxLtv, NEXT.band), bandGaps(maxLtv, NEXT.band));
  for (const maxLtv of [7000, 12600]) assert.throws(() => larkGaps(maxLtv, NEXT.band), /within 50% under/);
});

test("the approved band becomes per-vault gaps against each collateral's live max LTV", async () => {
  assert.deepEqual(bandGaps(7500, NEXT.band), { target: 0, relever: 1000, delever: 800 });
  assert.deepEqual(bandGaps(8000, NEXT.band), { target: 500, relever: 1000, delever: 800 });
  assert.throws(() => bandGaps(7000, NEXT.band), /max LTV 7000/);
  assert.throws(() => bandGaps(12600, NEXT.band), /within 50%/);
  assert.deepEqual(parseBand(" 6500, 7500,8300"), NEXT.band);
  const state = await read(nextChain());
  assert.deepEqual(state.vaults.map(v => [v.maxLtv, v.gaps]), [[7500, { target: 0, relever: 500, delever: 300 }], [8000, { target: 0, relever: 500, delever: 300 }]]);
  const calls = nextCalls(state, { band: NEXT.band });
  assert.deepEqual(calls.map(c => c.to), [LOOP, LOOP]);
  assert.deepEqual(calls.map(c => decode("setRebalanceBand(address,uint16,uint16,uint16)", c.data).map(String)),
    [[V1, "0", "1000", "800"], [V2, "500", "1000", "800"]]);
  assert.ok(nextChecks(state, { band: NEXT.band }).every(c => !c.ok));
});

test("a set band needs no calls, and a moved max LTV shows up in readiness", async () => {
  const gaps = { [V1]: [0, 1000, 800], [V2]: [500, 1000, 800] };
  const state = await read(nextChain({ gaps }));
  assert.deepEqual(nextCalls(state, { band: NEXT.band }), []);
  const checks = nextChecks(state, { band: NEXT.band });
  assert.equal(checks.length, 2);
  assert.ok(checks.every(c => c.ok), JSON.stringify(checks));
  const moved = nextChecks(await read(nextChain({ gaps, ltv: { [ETH]: 7000, [BTC]: 8000 } })), { band: NEXT.band });
  assert.deepEqual(moved.map(c => c.ok), [false, true]);
  assert.equal(moved[0].detail, "6000/7000/7800 under max 7000");
  const lowered = await read(nextChain({ ltv: { [ETH]: 7000, [BTC]: 8000 } }));
  assert.throws(() => nextCalls(lowered, { band: NEXT.band }), /max LTV 7000/);
});

test("bands are validated and need the next loop", async () => {
  const state = await read(nextChain());
  for (const band of [{ relever: 7500, target: 7500, delever: 8300 }, { relever: 6500, target: 7500, delever: 7500 },
    { relever: 2000, target: 7500, delever: 8300 }, { relever: 6500, target: 7500, delever: 10100 }, { relever: 6500.5, target: 7500, delever: 8300 }]) {
    assert.throws(() => nextCalls(state, { band }), /relever < target < delever/);
  }
  const old = await read(nextChain({ old: true }));
  assert.throws(() => nextCalls(old, { band: NEXT.band }), /rebalanceBand missing on chain/);
  assert.deepEqual(nextChecks(old, { band: NEXT.band }).map(c => c.detail), ["unreadable", "unreadable"]);
});

test("the revenue mix sets both discounts and every vault's fee, once", async () => {
  const revenue = { protocolFeeBps: 6000, mainDiscountBps: 8000, loopDiscountBps: 8000 };
  const calls = nextCalls(await readAll(nextChain()), { revenue });
  assert.deepEqual(calls.map(c => c.label.split("(")[0]), ["discount.setDiscountBps", "discount.setLoopDiscountBps", "fees.setProtocolFeeBps", "fees.setProtocolFeeBps"]);
  assert.deepEqual(calls.map(c => c.to), [DISC, DISC, FEES, FEES]);
  assert.equal(Number(decode("setDiscountBps(uint16)", calls[0].data)[0]), 8000);
  assert.equal(Number(decode("setLoopDiscountBps(uint16)", calls[1].data)[0]), 8000);
  assert.deepEqual(decode("setProtocolFeeBps(address,uint16)", calls[3].data).map(String), [V2, "6000"]);
  assert.deepEqual(nextCalls(await readAll(nextChain({ main: 8000, loopRate: 8000, fee: 6000 })), { revenue }), []);
});

test("the revenue mix waits for an installed discount and an enrolled loop", async () => {
  const revenue = { protocolFeeBps: 6000, mainDiscountBps: 8000, loopDiscountBps: 8000 };
  const cases: [Parameters<typeof nextChain>[0], RegExp][] = [
    [{ installed: false }, /install JuicerDiscount/], [{ enrolled: false }, /enroll the loop/],
    [{ loopRate: null }, /loop rate missing on chain/], [{ fee: null }, /not registered in the fee controller/],
  ];
  for (const [chain, error] of cases) {
    const state = await readAll(nextChain(chain));
    assert.throws(() => nextCalls(state, { revenue }), error);
  }
  assert.deepEqual(nextCalls(await readAll(nextChain({ enrolled: false })), { revenue: { ...revenue, loopDiscountBps: 0 } }).length, 3);
  const bare = await read(nextChain()), all = await readAll(nextChain());
  assert.throws(() => nextCalls(bare, { revenue }), /JUICER_DISCOUNT_CONTROLLER/);
  assert.throws(() => nextCalls(all, { revenue: { ...revenue, protocolFeeBps: 10001 } }), /0\.\.10000/);
});

test("deposit admission rises from the contract's 50 to the launch cap, once", async () => {
  const admissionMaxDeficitBps = NEXT.admissionMaxDeficitBps;
  const state = await read(nextChain());
  const calls = nextCalls(state, { admissionMaxDeficitBps });
  assert.deepEqual(calls.map(c => [c.to, c.label]), [[LOOP, "subLoop.setAdmissionMaxDeficitBps(250)"]]);
  assert.equal(Number(decode("setAdmissionMaxDeficitBps(uint16)", calls[0].data)[0]), 250);
  assert.deepEqual(nextChecks(state, { admissionMaxDeficitBps }).map(c => [c.ok, c.detail]), [[false, "50"]]);
  const set = await read(nextChain({ admission: 250 }));
  assert.deepEqual(nextCalls(set, { admissionMaxDeficitBps }), []);
  assert.deepEqual(nextChecks(set, { admissionMaxDeficitBps }).map(c => c.ok), [true]);
  for (const bad of [10001, 1.5, -1]) assert.throws(() => nextCalls(state, { admissionMaxDeficitBps: bad }), /admission deficit cap/);
  const old = await read(nextChain({ admission: null }));
  assert.throws(() => nextCalls(old, { admissionMaxDeficitBps }), /admissionMaxDeficitBps missing on chain/);
});

test("an empty env var fails loudly instead of becoming zero", () => {
  assert.equal(envNumber("X", 100, {}), 100);
  assert.equal(envNumber("X", 100, { X: "0" }), 0);
  assert.equal(envNumber("X", 100, { X: " 6900 " }), 6900);
  assert.ok(Number.isNaN(envNumber("X", NaN, {})));
  assert.throws(() => envNumber("X", 100, { X: "" }), /X is set but empty/);
  assert.throws(() => envNumber("X", 100, { X: "  " }), /X is set but empty/);
  assert.throws(() => envNumber("X", 100, { X: "4k" }), /X=4k is not a number/);
});

test("headroom exits switch on per vault, once, and readiness reads them back", async () => {
  const exitHeadroom = NEXT.exitHeadroom;
  const state = await read(nextChain());
  const calls = nextCalls(state, { exitHeadroom });
  assert.deepEqual(calls.map(c => [c.to, c.label.split("(")[0]]), [[LOOP, "subLoop.setExitHeadroom"], [LOOP, "subLoop.setExitHeadroom"]]);
  assert.deepEqual(decode("setExitHeadroom(address,bool,uint16)", calls[1].data).map(String), [V2, "true", "0"]);
  assert.deepEqual(nextChecks(state, { exitHeadroom }).map(c => [c.ok, c.detail]), [[false, "off"], [false, "off"]]);
  const on = await read(nextChain({ headroom: [true, 0] }));
  assert.deepEqual(nextCalls(on, { exitHeadroom }), []);
  assert.deepEqual(nextChecks(on, { exitHeadroom }).map(c => c.ok), [true, true]);
  assert.equal(nextCalls(on, { exitHeadroom: { enabled: true, gapBps: 500 } }).length, 2, "a new gap is a change");
  assert.throws(() => nextCalls(state, { exitHeadroom: { enabled: true, gapBps: 10001 } }), /exit headroom gap/);
  const old = await read(nextChain({ headroom: null }));
  assert.throws(() => nextCalls(old, { exitHeadroom }), /exitHeadroom missing on chain/);
});

test("exit headroom reads off, on, or on with a gap", () => {
  assert.deepEqual(parseExitHeadroom("off"), { enabled: false, gapBps: 0 });
  assert.deepEqual(parseExitHeadroom("on"), { enabled: true, gapBps: 0 });
  assert.deepEqual(parseExitHeadroom(" on , 500 "), { enabled: true, gapBps: 500 });
  for (const bad of ["", "yes", "off,10", "on,10001", "on,1.5", "on,1,2"]) assert.throws(() => parseExitHeadroom(bad), /exit headroom/);
});
