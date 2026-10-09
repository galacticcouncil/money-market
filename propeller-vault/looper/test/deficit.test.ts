import assert from 'node:assert/strict';
import { test } from 'node:test';
import { type Address } from 'viem';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import { deficitLevel, deficitStopped, vaultDeficitBps } from '../src/deficit-policy.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const ETH = '0x00000000000000000000000000000000000000e7';
const BTC = '0x00000000000000000000000000000000000000b7';
const TARGET = 1050000000000000000n;
const DEBT = 10_000n * 10n ** 18n;

type VaultState = { deficit: bigint; grossUp: bigint; unallocated: boolean; stop: boolean; frozen: boolean };

// one chain shared by every keeper instance
function chain(names: Address[] = [ETH, BTC]) {
  const c = {
    carry: 0n as bigint | Error,
    vaults: Object.fromEntries(names.map(v => [v, {deficit: 0n, grossUp: 0n, unallocated: false, stop: false, frozen: false}])) as
      Record<Address, VaultState>,
    calls: [] as string[],
    denied: new Set<string>(),
    // the other operator's setDeficitStop lands between this one's read and its transaction
    race: false,
  };
  return c;
}
type Chain = ReturnType<typeof chain>;

function keeper(c: Chain, name: 'k0' | 'k1', index: number) {
  const k = Object.create(PropellerLooper.prototype) as any;
  Object.assign(k, { cycle: 0, subLoop: LOOP, vaults: Object.keys(c.vaults), harvester: '', pool: '', index });
  k.readLeverage = async () => null;
  k.read = async (_abi: unknown, address: string, fn: string, args: any[] = []) => {
    const [tag, vault] = address.split(':') as [string, Address | undefined];
    const v = c.vaults[(vault ?? address) as Address];
    const views: Record<string, () => unknown> = {
      effectiveHealthFactor: () => 2n * TARGET, targetHf: () => TARGET, unwindTargetEquity: () => 0n, deleverDebtTarget: () => 0n,
      emergencyPaused: () => false, pendingUnwindOf: () => 0n,
      negativeCarryBps: () => { if (c.carry instanceof Error) throw c.carry; return c.carry; },
      equityOf: () => (10_000n - c.vaults[args[0] as Address].deficit) * 10n ** 8n,
      paused: () => address === LOOP ? false : v.frozen,
      queueHead: () => 0n, queueTail: () => 0n, queueUnwind: () => 0n, deleverTarget: () => 0n, reinvestAssets: () => 0n,
      deficitStop: () => v.stop, mainDebt: () => `L:${address}`, yieldAccounting: () => `A:${address}`,
      activePosition: () => { assert.equal(tag, 'L'); return [DEBT, DEBT, 0n]; },
      activeFunds: () => 0n, pendingSourceAccounting: () => v.unallocated,
      sourceValue: () => { assert.equal(tag, 'A'); return 0n; },
      // debt less active cash, plus the protocol fee on interest that only yield can still pay
      requiredSourceBacking: () => { assert.equal(tag, 'A'); return DEBT + v.grossUp; },
      // governance's own pause; keepers must neither read nor touch it
      depositsPaused: () => assert.fail('the keeper read depositsPaused'),
    };
    assert.ok(fn in views, `unexpected read ${fn}`);
    return views[fn]();
  };
  k.poke = async (_abi: unknown, address: Address, fn: string, _label: string, args: unknown[] = []) => {
    if (fn === 'maintainPeg') return false;
    c.calls.push(`${name}:${fn}${address === LOOP ? '' : `:${address === ETH ? 'eth' : 'btc'}`}${args.length ? `(${args})` : ''}`);
    const v = c.vaults[address];
    if (fn === 'setDeficitStop') {
      if (c.race) { c.race = false; v.stop = args[0] as boolean; return false; }
      if (c.denied.has(name) || v.stop === args[0]) return false;
      v.stop = args[0] as boolean;
    }
    return true;
  };
  return k;
}

// one maintenance cycle on or off this operator's duty slot; returns its calls and alerts
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

test('deficit math: the larger of the uncovered debt and the grossed-up requirement, rounded up', () => {
  const e18 = 10n ** 18n;
  assert.equal(vaultDeficitBps(0n, 0n, 0n, 0n, 0n), 0n);
  assert.equal(vaultDeficitBps(DEBT, 9_950n * 10n ** 8n, 0n, 0n, DEBT), 50n);
  // reward value is not backing; active cash is
  assert.equal(vaultDeficitBps(DEBT, 10_000n * 10n ** 8n, 60n * e18, 10n * e18, DEBT - 10n * e18), 50n);
  assert.equal(vaultDeficitBps(DEBT, 9_950n * 10n ** 8n, 0n, 1n, DEBT - 1n), 50n, 'a wei short still counts');
  // fully backed debt can still lack the fee its unpaid interest owes out of yield
  assert.equal(vaultDeficitBps(DEBT, 10_000n * 10n ** 8n, 0n, 0n, DEBT + 30n * e18), 30n);
  assert.equal(vaultDeficitBps(DEBT, 10_000n * 10n ** 8n, 0n, 0n, DEBT), 0n);
  assert.ok(vaultDeficitBps(DEBT, 0n, 1n, 0n, DEBT) > 10_000n);
  assert.equal(vaultDeficitBps(DEBT, 20_000n * 10n ** 8n, 0n, 0n, DEBT), 0n);
});

test('hysteresis: above 50 stops, below 25 resumes, the band keeps the current flag', () => {
  const step = (bps: bigint, stopped: boolean) => deficitStopped(bps, stopped, 50n, 25n);
  assert.equal(step(50n, false), false);
  assert.equal(step(51n, false), true);
  assert.equal(step(30n, true), true);
  assert.equal(step(30n, false), false);
  assert.equal(step(25n, true), true);
  assert.equal(step(24n, true), false);
  assert.equal(deficitLevel([10n, undefined], 50n), undefined, 'a partial view cannot resume');
  assert.equal(deficitLevel([undefined, 60n], 50n), 60n, 'but can stop');
  assert.equal(deficitLevel([10n, 30n], 50n), 30n);
});

test('a deficit above the stop halts the ramp and sets the flags on any operator, once', async () => {
  const c = chain();
  const k = keeper(c, 'k0', 0);
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow']);
  c.carry = 60n;
  const first = await run(c, k, false);
  assert.deepEqual(first.calls, ['k0:setDeficitStop:eth(true)', 'k0:setDeficitStop:btc(true)']);
  assert.deepEqual(first.alerts.filter(a => a.startsWith('[ALERT] deficit stop') && a.includes('deficitStop set')).length, 2);
  const again = await run(c, k);
  assert.deepEqual(again.calls, [], 'no ramp, and no transaction for a flag that is already set');
  assert.deepEqual(again.alerts, []);
});

test('the fee gross-up alone can stop a vault whose debt is otherwise backed', async () => {
  const c = chain([ETH]);
  c.vaults[ETH].grossUp = 60n * 10n ** 18n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:setDeficitStop:eth(true)']);
});

test('a single vault deficit sets only that vault\'s flag but stops the shared ramp', async () => {
  const c = chain();
  c.vaults[BTC].deficit = 51n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:setDeficitStop:btc(true)']);
  assert.equal(c.vaults[ETH].stop, false);
});

test('the band leaves the flag as it is; below resume the operator on duty clears it', async () => {
  const c = chain([ETH]);
  const k = keeper(c, 'k0', 0);
  c.vaults[ETH].deficit = 40n;
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow'], 'rising into the band does not stop');
  c.vaults[ETH].deficit = 60n;
  assert.deepEqual((await run(c, k)).calls, ['k0:setDeficitStop:eth(true)']);
  c.vaults[ETH].deficit = 40n;
  assert.deepEqual((await run(c, k)).calls, [], 'falling into the band keeps the stop');
  c.vaults[ETH].deficit = 25n;
  assert.deepEqual((await run(c, k)).calls, []);
  c.vaults[ETH].deficit = 24n;
  const resumed = await run(c, k);
  assert.deepEqual(resumed.calls, ['k0:setDeficitStop:eth(false)', 'k0:pokeBorrow']);
  assert.ok(resumed.alerts.some(a => a.startsWith('[ALERT] deficit resume') && a.includes('deficitStop cleared')));
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow']);
});

test('governance\'s depositsPaused is neither read nor touched; the keeper only owns deficitStop', async () => {
  const c = chain([ETH]);
  const k = keeper(c, 'k0', 0);
  for (const [deficit, expected] of [[0n, ['k0:pokeBorrow']], [70n, ['k0:setDeficitStop:eth(true)']],
    [10n, ['k0:setDeficitStop:eth(false)', 'k0:pokeBorrow']]] as const) {
    c.vaults[ETH].deficit = deficit;
    const {calls, alerts} = await run(c, k);
    assert.deepEqual(calls, expected);
    assert.ok(!alerts.some(a => a.includes('read failed')), 'the deficit view never depends on depositsPaused');
  }
});

test('a restarted keeper takes the band state from the flag', async () => {
  const c = chain([ETH]);
  c.vaults[ETH].deficit = 60n;
  await run(c, keeper(c, 'k0', 0));
  c.vaults[ETH].deficit = 40n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, [], 'no ramp and no clear in the band after a restart');
  c.vaults[ETH].deficit = 10n;
  assert.deepEqual((await run(c, keeper(c, 'k0', 0))).calls, ['k0:setDeficitStop:eth(false)', 'k0:pokeBorrow']);
});

test('two instances: one flag between them, cleared on the duty slot without flapping', async () => {
  const c = chain([ETH]);
  const k0 = keeper(c, 'k0', 0), k1 = keeper(c, 'k1', 1);
  c.vaults[ETH].deficit = 60n;
  assert.deepEqual((await run(c, k0, false)).calls, ['k0:setDeficitStop:eth(true)']);
  assert.deepEqual((await run(c, k1, true)).calls, [], 'the second instance sees the flag and adds nothing');
  c.vaults[ETH].deficit = 10n;
  assert.deepEqual((await run(c, k0, false)).calls, [], 'clearing waits for the duty slot');
  assert.deepEqual((await run(c, k1, true)).calls, ['k1:setDeficitStop:eth(false)', 'k1:pokeBorrow']);
  assert.deepEqual((await run(c, k0, true)).calls, ['k0:pokeBorrow'], 'the other instance does not flap it back');
  // both see the same rise; the one whose transaction loses the race is not alarmed
  c.vaults[ETH].deficit = 60n;
  c.race = true;
  const late = await run(c, k1, false);
  assert.deepEqual(late.calls, ['k1:setDeficitStop:eth(true)']);
  assert.ok(late.alerts.some(a => a.includes('deficitStop set')) && !late.alerts.some(a => a.includes('not confirmed')));
});

test('a frozen vault keeps its flag until the freeze lifts', async () => {
  const c = chain([ETH]);
  const k = keeper(c, 'k0', 0);
  c.vaults[ETH].deficit = 60n;
  await run(c, k);
  c.vaults[ETH].deficit = 0n;
  c.vaults[ETH].frozen = true;
  assert.deepEqual((await run(c, k)).calls, []);
  c.vaults[ETH].frozen = false;
  assert.deepEqual((await run(c, k)).calls, ['k0:setDeficitStop:eth(false)', 'k0:pokeBorrow']);
});

test('an unreadable or unallocated view holds the flag and the ramp', async () => {
  const c = chain([ETH]);
  const k = keeper(c, 'k0', 0);
  c.carry = new Error('rpc down');
  const down = await run(c, k);
  assert.deepEqual(down.calls, []);
  assert.ok(down.alerts.some(a => a.includes('source deficit read failed')));
  c.carry = 0n;
  // stale active cash during allocation must not stop anything; pokeSettle comes first
  c.vaults[ETH].unallocated = true;
  c.vaults[ETH].deficit = 80n;
  const stale = await run(c, k);
  assert.ok(!stale.calls.some(x => x.includes('setDeficitStop')));
  assert.ok(!stale.calls.includes('k0:pokeBorrow'));
  // a source stop needs no vault view
  c.carry = 70n;
  assert.ok((await run(c, k)).calls.includes('k0:setDeficitStop:eth(true)'));
});

test('a keeper without the deposit guardian role still stops the ramp and alerts once, retrying every cycle', async () => {
  const c = chain([ETH]);
  const k = keeper(c, 'k0', 0);
  c.denied.add('k0');
  c.vaults[ETH].deficit = 70n;
  const first = await run(c, k);
  assert.deepEqual(first.calls, ['k0:setDeficitStop:eth(true)']);
  assert.ok(first.alerts.includes(`[ALERT] deficit stop ${ETH}: setDeficitStop(true) not confirmed; retrying every cycle`));
  const second = await run(c, k);
  assert.deepEqual(second.calls, ['k0:setDeficitStop:eth(true)']);
  assert.deepEqual(second.alerts, []);
  c.denied.clear();
  assert.ok((await run(c, k)).alerts.some(a => a.includes('deficitStop set')));
});
