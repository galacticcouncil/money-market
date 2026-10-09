import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  decodeFunctionData, encodeAbiParameters, encodeEventTopics, parseAbi, toFunctionSelector, type Address, type Hex,
} from 'viem';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import { ENTRY, EXIT, intentRoute, palletIntentId, quoteRate, submittedIntent } from '../src/intent-policy.js';
import type { Hop, Substrate } from '../src/substrate.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const VAULT = '0x0000000000000000000000000000000000000002';
const KEEPER = '0x00000000000000000000000000000000000000a0';
const LOOP_ACCOUNT = `0x45544800${LOOP.slice(2)}0000000000000000` as Hex;
const TARGET = 1050000000000000000n;
const E18 = 10n ** 18n;
const IDS = { hollar: 222, prime: 43, aPrime: 1043, pool: 143 };
const EVENTS = parseAbi([
  'event IntentSubmitted(uint8 indexed kind, uint64 indexed nonce, uint256 amountIn, uint256 minOut, uint64 deadline)',
]);
const CALLS = parseAbi([
  'function pokeBorrowQuoted(uint256)', 'function pokeRepayQuoted(uint256)', 'function pokeBorrow()', 'function pokeRepay()',
]);

function intentLog(kind: number, nonce: bigint, amountIn: bigint) {
  return {
    address: LOOP as Address,
    topics: encodeEventTopics({abi: EVENTS, eventName: 'IntentSubmitted', args: {kind, nonce}}) as Hex[],
    data: encodeAbiParameters([{type: 'uint256'}, {type: 'uint256'}, {type: 'uint64'}], [amountIn, 1n, 99n]),
  };
}

type Pending = { nonce: bigint; deadline: bigint; kind: number; amountIn: bigint };

// one chain and its substrate side, shared by every keeper instance
function chain() {
  const c = {
    ttl: 60, hf: 2n * TARGET, unwind: 0n, safetyDebt: 0n, emergency: false, idle: 0n, nonce: 0n,
    head: {number: 1_000n, timestamp: 10_000n},
    pending: undefined as Pending | undefined,
    outcome: 1,
    // what the loop's next poke would submit, per direction
    next: {[ENTRY]: undefined as bigint | undefined, [EXIT]: undefined as bigint | undefined},
    keeperRole: true,
    probeFails: false, outage: false,
    routerOut: (kind: number, amountIn: bigint): bigint => kind === ENTRY ? amountIn * 94n / 100n / 10n ** 12n : amountIn * 106n * 10n ** 10n,
    routerFails: false,
    palletIntents: [] as { id: bigint; amountIn: bigint }[],
    signer: false,
    calls: [] as string[], sells: [] as {origin: Hex; route: readonly Hop[]; amountIn: bigint}[],
    probes: [] as string[], cleanups: [] as bigint[],
  };
  return c;
}
type Chain = ReturnType<typeof chain>;

function substrate(c: Chain): Substrate {
  return {
    accountOf: async address => { assert.equal(address, LOOP); return LOOP_ACCOUNT; },
    free: async (asset, account) => { assert.deepEqual([asset, account], [IDS.hollar, LOOP_ACCOUNT]); return c.idle; },
    dryRunEvm: async (from, to, data) => {
      if (c.outage) throw new Error('connection refused');
      assert.deepEqual([from, to], [KEEPER, LOOP]);
      const {functionName, args} = decodeFunctionData({abi: CALLS, data});
      c.probes.push(`${functionName}(${args ?? ''})`);
      if (c.probeFails) return undefined;
      const kind = functionName.startsWith('pokeBorrow') ? ENTRY : EXIT;
      const amountIn = c.next[kind];
      return amountIn === undefined ? [] : [intentLog(kind, c.nonce + 1n, amountIn)];
    },
    dryRunSell: async (origin, route, amountIn) => {
      if (c.routerFails) throw new Error('router dry run did not fill');
      c.sells.push({origin, route, amountIn});
      return c.routerOut(route[0].assetIn === IDS.hollar ? ENTRY : EXIT, amountIn);
    },
    intents: async owner => { assert.equal(owner, LOOP_ACCOUNT); return c.palletIntents; },
    cleanup: c.signer ? async id => { c.cleanups.push(id); return '0xfeed'; } : undefined,
  };
}

function keeper(c: Chain, name: 'k0' | 'k1', index: number) {
  const k = Object.create(PropellerLooper.prototype) as any;
  Object.assign(k, {cycle: 0, subLoop: LOOP, vaults: [VAULT], harvester: '', pool: '', index, account: {address: KEEPER}});
  k.readLeverage = async () => null;
  k.chain = async () => substrate(c);
  k.publicClient = {
    getBlock: async () => ({...c.head, gasLimit: 45_000_000n}),
    getGasPrice: async () => 100n,
  };
  k.read = async (_abi: unknown, address: string, fn: string, args: any[] = []) => {
    const p = c.pending;
    const views: Record<string, () => unknown> = {
      effectiveHealthFactor: () => c.hf, targetHf: () => TARGET, unwindTargetEquity: () => c.unwind,
      deleverDebtTarget: () => c.safetyDebt, paused: () => false, emergencyPaused: () => c.emergency,
      intentTtl: () => c.ttl, negativeCarryBps: () => 0n, equityOf: () => 0n, pendingUnwindOf: () => 0n,
      pendingIntent: () => p ? [p.nonce, p.deadline, p.kind, false, p.amountIn, 0n, 0n, 0n, 0n] : [0n, 0n, 0, false, 0n, 0n, 0n, 0n, 0n],
      reconcile: () => p ? c.outcome : 0,
      hasRole: () => { assert.equal(args[1], KEEPER); return c.keeperRole; },
      hollar: () => '0x00000000000000000000000000000000000000dd', reservedFreed: () => 0n, balanceOf: () => c.idle,
      hollarAssetId: () => IDS.hollar, primeAssetId: () => IDS.prime, aPrimeAssetId: () => IDS.aPrime, primePoolId: () => IDS.pool,
      queueHead: () => 0n, queueTail: () => 0n, queueUnwind: () => 0n, deleverTarget: () => 0n, reinvestAssets: () => 0n,
      mainDebt: () => VAULT, pendingSourceAccounting: () => false, deficitStop: () => false, yieldAccounting: () => VAULT,
      activePosition: () => [0n, 0n, 0n], activeFunds: () => 0n, sourceValue: () => 0n, requiredSourceBacking: () => 0n,
    };
    if (!(fn in views)) throw new Error(`no view ${fn}`);
    return views[fn]();
  };
  k.poke = async (abi: any[], address: string, fn: string, _label: string, args: unknown[] = [], direct = false) => {
    if (fn === 'maintainPeg') return false;
    const kind0 = fn.startsWith('pokeBorrow') ? ENTRY : fn.startsWith('pokeRepay') ? EXIT : 0;
    if (kind0 && direct && c.next[kind0] !== undefined) {
      // a submission the dry run proved must not be dropped by the zero-work guard
      assert.deepEqual(abi.find(item => item.name === fn).outputs, [], `${fn} is sent with a void abi`);
    }
    c.calls.push(`${name}:${fn}${args.length ? `(${args})` : ''}${direct || address !== LOOP ? '' : ' via controller'}`);
    const kind = fn.startsWith('pokeBorrow') ? ENTRY : fn.startsWith('pokeRepay') ? EXIT : 0;
    if (kind && direct && !c.pending && c.next[kind] !== undefined) {
      c.pending = {nonce: ++c.nonce, deadline: (c.head.timestamp + 60n) * 1000n, kind, amountIn: c.next[kind]!};
    }
    if (fn === 'reconcile' || fn === 'removeIntent') c.pending = undefined;
    return true;
  };
  return k;
}

async function run(c: Chain, k: any, duty = true) {
  const [count, index] = [CONFIG.OPERATOR_COUNT, CONFIG.OPERATOR_INDEX];
  const [log, error] = [console.log, console.error];
  const alerts: string[] = [];
  CONFIG.OPERATOR_COUNT = 2;
  CONFIG.OPERATOR_INDEX = k.index;
  k.blockTimestamp = async () => 60n * BigInt(duty ? k.index : 1 - k.index);
  c.calls = [];
  console.log = () => {};
  console.error = (...args: unknown[]) => { alerts.push(args.join(' ')); };
  try { await k.runCycle(); } finally {
    CONFIG.OPERATOR_COUNT = count; CONFIG.OPERATOR_INDEX = index;
    console.log = log; console.error = error;
  }
  return {calls: c.calls, alerts};
}

test('keeper quotes are output units per 1e18 input, read from dry runs of the real size', () => {
  assert.equal(quoteRate(1000n * E18, 939_812_624n), 939_812n, 'entry ~1e6 at $1/$1');
  assert.equal(quoteRate(500_000_000n, 531n * E18), 1_062_000_000_000_000_000_000_000_000_000n, 'exit ~1e30');
  assert.throws(() => quoteRate(1n, 0n), /empty/);
  assert.deepEqual(intentRoute(ENTRY, IDS), [
    {pool: {Stableswap: 143}, assetIn: 222, assetOut: 43}, {pool: 'Aave', assetIn: 43, assetOut: 1043}]);
  assert.deepEqual(intentRoute(EXIT, IDS), [
    {pool: 'Aave', assetIn: 1043, assetOut: 43}, {pool: {Stableswap: 143}, assetIn: 43, assetOut: 222}]);
  const other = {...intentLog(ENTRY, 3n, 5n), address: VAULT as Address};
  assert.deepEqual(submittedIntent([other, intentLog(EXIT, 3n, 7n)], LOOP),
    {kind: EXIT, nonce: 3n, amountIn: 7n, minOut: 1n, deadline: 99n});
  assert.equal(submittedIntent([other], LOOP), undefined);
  assert.equal(palletIntentId([{id: 9n, amountIn: 1n}], 5n), 9n, 'the loop owns at most one intent');
  assert.equal(palletIntentId([{id: 9n, amountIn: 1n}, {id: 8n, amountIn: 5n}], 5n), 8n);
  assert.equal(palletIntentId([{id: 9n, amountIn: 5n}, {id: 8n, amountIn: 5n}], 5n), undefined);
});

test('an entry is sized by a dry run of the loop\'s own call and quoted on the router at that size', async () => {
  const c = chain();
  c.next[ENTRY] = 1000n * E18;
  const {calls} = await run(c, keeper(c, 'k0', 0));
  assert.deepEqual(c.probes, ['pokeBorrowQuoted(0)']);
  assert.deepEqual(calls, ['k0:pokeBorrowQuoted(940000)']);
  // the loop holds no HOLLAR before its own borrow, so another holder stands in for the dry run
  assert.deepEqual(c.sells, [{origin: CONFIG.ICE_QUOTE_HOLDER, route: intentRoute(ENTRY, IDS), amountIn: 1000n * E18}]);
  c.pending = undefined;
  c.idle = 1000n * E18;
  await run(c, keeper(c, 'k0', 0));
  assert.equal(c.sells[1].origin, LOOP_ACCOUNT, 'cash the loop already holds quotes from the loop itself');
});

test('an exit is quoted from the loop\'s own aPRIME at its real slice size', async () => {
  const c = chain();
  c.unwind = 1n;
  c.next[EXIT] = 500_000_000n;
  const {calls} = await run(c, keeper(c, 'k0', 0));
  assert.deepEqual(calls, ['k0:pokeRepayQuoted(1060000000000000000000000000000)']);
  assert.deepEqual(c.sells, [{origin: LOOP_ACCOUNT, route: intentRoute(EXIT, IDS), amountIn: 500_000_000n}]);
});

test('nothing new is submitted, or even probed, while an intent is in flight', async () => {
  const c = chain();
  c.unwind = 1n;
  c.next = {[ENTRY]: E18, [EXIT]: 5n};
  c.pending = {nonce: 4n, deadline: (c.head.timestamp + 60n) * 1000n, kind: EXIT, amountIn: 5n};
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, []);
  assert.deepEqual(c.probes, []);
});

test('a fill or refund that landed without its callback is reconciled on the duty slot, then the loop moves on', async () => {
  const c = chain();
  c.next[ENTRY] = E18;
  c.pending = {nonce: 4n, deadline: (c.head.timestamp - 1n) * 1000n, kind: ENTRY, amountIn: E18};
  c.outcome = 3;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0), false)).calls, [], 'the other operator settles it');
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:reconcile', 'k0:pokeBorrowQuoted(940000)']);
  c.outcome = 1;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, [], 'a waiting intent is not reconciled');
});

test('a quiet solver and a slow expiry are reported once, after their block allowances', async () => {
  const c = chain();
  const k = keeper(c, 'k0', 0);
  c.pending = {nonce: 4n, deadline: (c.head.timestamp + 30n) * 1000n, kind: ENTRY, amountIn: E18};
  assert.deepEqual((await run(c, k)).alerts, []);
  c.head = {number: c.head.number + BigInt(CONFIG.ICE_STALL_BLOCKS) - 1n, timestamp: c.head.timestamp + 20n};
  assert.deepEqual((await run(c, k)).alerts, []);
  c.head = {...c.head, number: c.head.number + 1n};
  const quiet = await run(c, k);
  assert.deepEqual(quiet.alerts, [`[ALERT] entry intent #4 unfilled for ${CONFIG.ICE_STALL_BLOCKS} blocks: solver quiet or its limit out of reach`]);
  assert.deepEqual((await run(c, k)).alerts, [], 'once per intent');
  // past the deadline, the refund gets its own allowance before anyone is told
  c.head = {number: c.head.number + 1n, timestamp: c.head.timestamp + 60n};
  assert.deepEqual((await run(c, k)).alerts, []);
  c.head = {...c.head, number: c.head.number + BigInt(CONFIG.ICE_CLEANUP_BLOCKS)};
  const late = await run(c, k);
  assert.deepEqual(late.alerts, [`[ALERT] entry intent #4 expired ${CONFIG.ICE_CLEANUP_BLOCKS} blocks ago and its input is still away; no cleanup signer`]);
  assert.deepEqual(late.calls, []);
  assert.deepEqual((await run(c, k)).alerts, []);
});

test('with a dev signer an expired intent is cleaned up by its pallet id, on the duty slot', async () => {
  const c = chain();
  c.signer = true;
  c.palletIntents = [{id: 77n, amountIn: E18}];
  c.pending = {nonce: 4n, deadline: (c.head.timestamp - 1n) * 1000n, kind: ENTRY, amountIn: E18};
  const k = keeper(c, 'k0', 0);
  await run(c, k);
  c.head = {...c.head, number: c.head.number + BigInt(CONFIG.ICE_CLEANUP_BLOCKS)};
  await run(c, k, false);
  assert.deepEqual(c.cleanups, [], 'off duty');
  const {alerts} = await run(c, k);
  assert.deepEqual(c.cleanups, [77n]);
  assert.ok(!alerts.some(a => a.includes('no cleanup signer')));
});

test('under an emergency pause any operator calls the intent home by its pallet id', async () => {
  const c = chain();
  c.emergency = true;
  c.pending = {nonce: 4n, deadline: (c.head.timestamp + 60n) * 1000n, kind: EXIT, amountIn: 5n};
  c.palletIntents = [{id: 81n, amountIn: 9n}, {id: 82n, amountIn: 5n}];
  assert.deepEqual((await run(c, keeper(c, 'k1', 1), false)).calls, ['k1:removeIntent(82)']);
  c.pending = {nonce: 5n, deadline: (c.head.timestamp + 60n) * 1000n, kind: EXIT, amountIn: 7n};
  const unknown = await run(c, keeper(c, 'k1', 1), false);
  assert.deepEqual(unknown.calls, []);
  assert.ok(unknown.alerts.some(a => a.includes('no pallet intent id')));
});

test('two instances: only the operator on duty submits, and nobody submits over an intent in flight', async () => {
  const c = chain();
  c.next[ENTRY] = E18;
  const k0 = keeper(c, 'k0', 0), k1 = keeper(c, 'k1', 1);
  assert.deepEqual((await run(c, k0, false)).calls, []);
  assert.deepEqual((await run(c, k1, true)).calls, ['k1:pokeBorrowQuoted(940000)']);
  assert.deepEqual((await run(c, k0, true)).calls, [], 'the intent k1 sent is still in flight');
  c.outcome = 2;
  assert.deepEqual((await run(c, k0, true)).calls, ['k0:reconcile', 'k0:pokeBorrowQuoted(940000)']);
});

test('without KEEPER_ROLE the keeper falls back to the permissionless pokes, sent directly, and says so once', async () => {
  const c = chain();
  c.keeperRole = false;
  c.next[ENTRY] = E18;
  const k = keeper(c, 'k0', 0);
  const first = await run(c, k);
  assert.deepEqual(first.calls, ['k0:pokeBorrow']);
  assert.deepEqual(c.probes, ['pokeBorrow()']);
  assert.deepEqual(c.sells, [], 'no quote to compute');
  assert.ok(first.alerts.includes('[ALERT] keeper lacks KEEPER_ROLE: intents carry only the oracle floor'));
  c.pending = undefined;
  assert.deepEqual((await run(c, k)).alerts, []);
});

test('a failed router dry run holds entries back but lets exits go out on the oracle floor', async () => {
  const c = chain();
  c.routerFails = true;
  c.next[ENTRY] = E18;
  const entry = await run(c, keeper(c, 'k0', 0));
  assert.deepEqual(entry.calls, []);
  assert.ok(entry.alerts.some(a => a.includes('router dry run for the entry quote failed')));
  c.next[ENTRY] = undefined;
  c.unwind = 1n;
  c.next[EXIT] = 5n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:pokeRepayQuoted(0)']);
});

test('a substrate outage or a failing dry run submits nothing; the outage alerts once', async () => {
  const c = chain();
  c.next[ENTRY] = E18;
  const k = keeper(c, 'k0', 0);
  c.outage = true;
  const first = await run(c, k);
  assert.deepEqual(first.calls, []);
  assert.ok(first.alerts.some(a => a.includes('entry intent probe failed')));
  assert.deepEqual((await run(c, k)).alerts, []);
  c.outage = false;
  c.probeFails = true;
  assert.deepEqual((await run(c, k)).calls, []);
});

test('idle deposit cash rides an entry even without ramp headroom', async () => {
  const c = chain();
  c.hf = TARGET;
  c.next[ENTRY] = 3n * E18;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, [], 'no headroom and no cash: nothing to probe');
  assert.deepEqual(c.probes, []);
  c.idle = 3n * E18;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:pokeBorrowQuoted(940000)']);
});

test('an exit probe with no intent to send still repays what an earlier fill brought back', async () => {
  const c = chain();
  c.unwind = 1n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:pokeRepayQuoted(0)']);
  assert.deepEqual(c.sells, []);
});

test('router mode keeps the controller path, and a safety repayment stays on the router in intent mode', async () => {
  const c = chain();
  c.ttl = 0;
  c.next[ENTRY] = E18;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:pokeBorrow via controller']);
  assert.deepEqual(c.probes, []);
  c.ttl = 60;
  c.safetyDebt = 1n;
  c.unwind = 1n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:pokeRepay via controller']);
});
