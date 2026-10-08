import assert from 'node:assert/strict';
import { test } from 'node:test';
import { keccak256, pad, toBytes, toHex, type Address, type Hex } from 'viem';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import {
  DEPOSIT_GUARDIAN_ROLE, DEPOSITS_PAUSED, DEPOSITS_UNPAUSED, deficitLevel, deficitState, eventAccount, vaultDeficitBps,
} from '../src/deficit-policy.js';
import { LOG_CHUNK_BLOCKS, LatestLog, REORG_MARGIN_BLOCKS, newestInChunks, type EvidenceLog } from '../src/log-evidence.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const ETH = '0x00000000000000000000000000000000000000e7';
const BTC = '0x00000000000000000000000000000000000000b7';
const KEEPER0 = '0x00000000000000000000000000000000000000a0';
const KEEPER1 = '0x00000000000000000000000000000000000000a1';
const GUARDIAN = '0x00000000000000000000000000000000000000b0';
const TARGET = 1050000000000000000n;
const GUARDIAN_ROLE = keccak256(toBytes('GUARDIAN_ROLE'));
const DEBT = 10_000n * 10n ** 18n;

type Shape = 'sender' | 'data' | 'indexed';
type VaultState = { deficit: bigint; unallocated: boolean; depositsPaused: boolean; frozen: boolean };

// one chain shared by every keeper instance: views, deposit pause events and their senders
function chain(names: Address[] = [ETH, BTC]) {
  const c = {
    block: 1_000n,
    carry: 0n as bigint | Error,
    vaults: Object.fromEntries(names.map(v => [v, {deficit: 0n, unallocated: false, depositsPaused: false, frozen: false}])) as
      Record<Address, VaultState>,
    logs: [] as any[],
    senders: new Map<Hex, Address>(),
    roles: new Map<Address, Hex[]>([
      [KEEPER0, [DEPOSIT_GUARDIAN_ROLE]], [KEEPER1, [DEPOSIT_GUARDIAN_ROLE]], [GUARDIAN, [GUARDIAN_ROLE, DEPOSIT_GUARDIAN_ROLE]],
    ]),
    calls: [] as string[],
    denied: new Set<Address>(),
    emit(vault: Address, paused: boolean, account: Address, shape: Shape = 'sender') {
      c.block += 1n;
      const tx = keccak256(toHex(`${vault}:${c.block}:${paused}`));
      c.senders.set(tx, account);
      const named = shape === 'sender' ? 0 : 1;
      c.logs.push({
        address: vault, blockNumber: toHex(c.block), logIndex: '0x0', transactionHash: tx, removed: false,
        topics: [(paused ? DEPOSITS_PAUSED : DEPOSITS_UNPAUSED)[named], ...(shape === 'indexed' ? [pad(account)] : [])],
        data: shape === 'data' ? pad(account) : '0x',
      });
    },
  };
  return c;
}
type Chain = ReturnType<typeof chain>;

function keeper(c: Chain, self: Address, index: number) {
  const k = Object.create(PropellerLooper.prototype) as any;
  Object.assign(k, { cycle: 0, subLoop: LOOP, vaults: Object.keys(c.vaults), harvester: '', pool: '', index });
  k.readLeverage = async () => null;
  k.read = async (_abi: unknown, address: string, fn: string, args: any[] = []) => {
    const [tag, vault] = address.split(':') as [string, Address | undefined];
    const v = c.vaults[(vault ?? address) as Address];
    const views: Record<string, () => unknown> = {
      healthFactor: () => 2n * TARGET, targetHf: () => TARGET, unwindTargetEquity: () => 0n, deleverDebtTarget: () => 0n,
      emergencyPaused: () => false, pendingUnwindOf: () => 0n,
      negativeCarryBps: () => { if (c.carry instanceof Error) throw c.carry; return c.carry; },
      equityOf: () => (10_000n - c.vaults[args[0] as Address].deficit) * 10n ** 8n,
      paused: () => address === LOOP ? false : v.frozen,
      queueHead: () => 0n, queueTail: () => 0n, queueUnwind: () => 0n, deleverTarget: () => 0n, reinvestAssets: () => 0n,
      depositsPaused: () => v.depositsPaused, mainDebt: () => `L:${address}`, yieldAccounting: () => `A:${address}`,
      hasRole: () => (c.roles.get(args[1].toLowerCase()) ?? []).includes(args[0]),
      activePosition: () => { assert.equal(tag, 'L'); return [DEBT, DEBT, 0n]; },
      activeFunds: () => 0n, pendingSourceAccounting: () => v.unallocated,
      sourceValue: () => { assert.equal(tag, 'A'); return 0n; },
    };
    assert.ok(fn in views, `unexpected read ${fn}`);
    return views[fn]();
  };
  k.publicClient = {
    getBlockNumber: async () => c.block,
    getTransaction: async ({hash}: {hash: Hex}) => ({from: c.senders.get(hash)}),
    request: async ({method, params: [filter]}: any) => {
      assert.equal(method, 'eth_getLogs');
      const addresses = [filter.address].flat().map((a: string) => a.toLowerCase());
      return c.logs.filter(l => addresses.includes(l.address.toLowerCase()) && filter.topics[0].includes(l.topics[0])
        && BigInt(l.blockNumber) >= BigInt(filter.fromBlock) && BigInt(l.blockNumber) <= BigInt(filter.toBlock));
    },
  };
  // pause and unpause revert when already in that state, as track A's guards would
  k.poke = async (_abi: unknown, address: Address, fn: string) => {
    if (fn === 'maintainPeg') return false;
    c.calls.push(`${self === KEEPER0 ? 'k0' : 'k1'}:${fn}${address === LOOP ? '' : `:${address === ETH ? 'eth' : 'btc'}`}`);
    const v = c.vaults[address];
    if (fn === 'pauseDeposits' || fn === 'unpauseDeposits') {
      const pausing = fn === 'pauseDeposits';
      if (v.depositsPaused === pausing || c.denied.has(self)) return false;
      v.depositsPaused = pausing;
      c.emit(address, pausing, self);
    }
    return true;
  };
  return k;
}

// runs one maintenance cycle on or off this operator's duty slot and returns the calls and alerts it made
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

test('deficit math: shortfall of active Main debt over its source backing, rounded up', () => {
  assert.equal(vaultDeficitBps(0n, 0n, 0n, 0n), 0n);
  assert.equal(vaultDeficitBps(DEBT, 9_950n * 10n ** 8n, 0n, 0n), 50n);
  // reward value is not backing; active cash is
  assert.equal(vaultDeficitBps(DEBT, 10_000n * 10n ** 8n, 60n * 10n ** 18n, 10n * 10n ** 18n), 50n);
  assert.equal(vaultDeficitBps(DEBT, 9_950n * 10n ** 8n, 0n, 1n), 50n, 'a wei short still counts');
  assert.equal(vaultDeficitBps(DEBT, 0n, 1n, 0n), 10_000n);
  assert.equal(vaultDeficitBps(DEBT, 20_000n * 10n ** 8n, 0n, 0n), 0n);
});

test('hysteresis: above 50 stops, below 25 resumes, the band keeps the previous state', () => {
  const step = (bps: bigint, previous: 'ok' | 'stopped') => deficitState(bps, previous, 50n, 25n);
  assert.equal(step(50n, 'ok'), 'ok');
  assert.equal(step(51n, 'ok'), 'stopped');
  assert.equal(step(30n, 'stopped'), 'stopped');
  assert.equal(step(30n, 'ok'), 'ok');
  assert.equal(step(25n, 'stopped'), 'stopped');
  assert.equal(step(24n, 'stopped'), 'ok');
  assert.equal(deficitLevel([10n, undefined], 50n), undefined, 'a partial view cannot resume');
  assert.equal(deficitLevel([undefined, 60n], 50n), 60n, 'but can stop');
  assert.equal(deficitLevel([10n, 30n], 50n), 30n);
});

test('the pauser comes from the event when it names one, otherwise from the transaction', () => {
  assert.equal(eventAccount({topics: [DEPOSITS_PAUSED[1], pad(KEEPER1)], data: '0x'})?.toLowerCase(), KEEPER1);
  assert.equal(eventAccount({topics: [DEPOSITS_PAUSED[1]], data: pad(KEEPER1)})?.toLowerCase(), KEEPER1);
  assert.equal(eventAccount({topics: [DEPOSITS_PAUSED[0]], data: '0x'}), undefined);
});

test('a deficit above the stop halts the ramp and pauses deposits, with one alert per transition', async () => {
  const c = chain();
  const k = keeper(c, KEEPER0, 0);
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow']);
  c.carry = 60n;
  const first = await run(c, k, false);
  assert.deepEqual(first.calls, ['k0:pauseDeposits:eth', 'k0:pauseDeposits:btc'], 'a safety pause does not wait for the duty slot');
  assert.equal(first.alerts.filter(a => a.includes('deficit stop') && a.includes('ramp stopped')).length, 2);
  assert.equal(first.alerts.filter(a => a.includes('deposits paused')).length, 2);
  const again = await run(c, k);
  assert.deepEqual(again.calls, [], 'no ramp and no repeated pause');
  assert.deepEqual(again.alerts, [], 'a held stop is not re-alerted');
});

test('a keeper without the deposit guardian role still stops the ramp and alerts once, retrying every cycle', async () => {
  const c = chain([ETH]);
  const k = keeper(c, KEEPER0, 0);
  c.denied.add(KEEPER0);
  c.vaults[ETH].deficit = 70n;
  const first = await run(c, k);
  assert.deepEqual(first.calls, ['k0:pauseDeposits:eth']);
  assert.ok(first.alerts.includes(`[ALERT] deficit stop ${ETH}: pauseDeposits not confirmed; retrying every cycle`));
  const second = await run(c, k);
  assert.deepEqual(second.calls, ['k0:pauseDeposits:eth']);
  assert.deepEqual(second.alerts, []);
  c.denied.clear();
  assert.ok((await run(c, k)).alerts.includes(`[ALERT] deficit stop ${ETH}: deposits paused`));
});

test('a single vault deficit pauses only that vault but stops the shared ramp', async () => {
  const c = chain();
  const k = keeper(c, KEEPER0, 0);
  c.vaults[BTC].deficit = 51n;
  assert.deepEqual((await run(c, k)).calls, ['k0:pauseDeposits:btc']);
  assert.equal(c.vaults[ETH].depositsPaused, false);
});

test('the band holds a stop until the deficit falls below resume, then the keeper reopens its own pause', async () => {
  const c = chain([ETH]);
  const k = keeper(c, KEEPER0, 0);
  c.vaults[ETH].deficit = 40n;
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow'], 'rising into the band does not stop');
  c.vaults[ETH].deficit = 60n;
  assert.deepEqual((await run(c, k)).calls, ['k0:pauseDeposits:eth']);
  c.vaults[ETH].deficit = 40n;
  assert.deepEqual((await run(c, k)).calls, [], 'falling into the band keeps the stop');
  c.vaults[ETH].deficit = 25n;
  assert.deepEqual((await run(c, k)).calls, []);
  c.vaults[ETH].deficit = 24n;
  const resumed = await run(c, k);
  assert.deepEqual(resumed.calls, ['k0:unpauseDeposits:eth', 'k0:pokeBorrow']);
  assert.ok(resumed.alerts.some(a => a.includes('ramp allowed')));
  assert.ok(resumed.alerts.some(a => a.includes('deposits reopened') && a.toLowerCase().includes(KEEPER0)));
  assert.deepEqual((await run(c, k)).calls, ['k0:pokeBorrow']);
});

test('a pause by governance or a guardian is never undone, whatever the deficit', async () => {
  for (const shape of ['sender', 'data', 'indexed'] as const) {
    const c = chain([ETH]);
    const k = keeper(c, KEEPER0, 0);
    c.vaults[ETH].depositsPaused = true;
    c.emit(ETH, true, GUARDIAN, shape);
    const first = await run(c, k);
    assert.deepEqual(first.calls, ['k0:pokeBorrow'], `guardian pause shape ${shape}: no deficit, no stop, no unpause`);
    assert.equal(first.alerts.filter(a => a.includes('deposits stay paused') && a.toLowerCase().includes(GUARDIAN)).length, 1);
    assert.deepEqual((await run(c, k)).alerts, [], 'the reason is reported once');
    assert.equal(c.vaults[ETH].depositsPaused, true);
  }
});

test('missing or contradictory pause evidence leaves deposits paused', async () => {
  const c = chain([ETH]);
  const k = keeper(c, KEEPER0, 0);
  c.vaults[ETH].depositsPaused = true;
  const none = await run(c, k);
  assert.deepEqual(none.calls, ['k0:pokeBorrow']);
  assert.ok(none.alerts.some(a => a.includes('no deposit pause event')));
  // a keeper paused and unpaused, then something without an event paused again
  c.emit(ETH, true, KEEPER0);
  c.emit(ETH, false, KEEPER0);
  const unpaused = await run(c, k);
  assert.deepEqual(unpaused.calls, ['k0:pokeBorrow']);
  assert.ok(unpaused.alerts.some(a => a.includes('newest deposit pause event is an unpause')));
  // a keeper pause followed by a governance re-pause: the newest pauser decides
  const d = chain([ETH]);
  const j = keeper(d, KEEPER0, 0);
  d.emit(ETH, true, KEEPER0);
  d.emit(ETH, false, GUARDIAN);
  d.emit(ETH, true, GUARDIAN);
  d.vaults[ETH].depositsPaused = true;
  assert.deepEqual((await run(d, j)).calls, ['k0:pokeBorrow']);
});

test('a frozen vault keeps its keeper pause until the freeze lifts', async () => {
  const c = chain([ETH]);
  const k = keeper(c, KEEPER0, 0);
  c.vaults[ETH].deficit = 60n;
  await run(c, k);
  c.vaults[ETH].deficit = 0n;
  c.vaults[ETH].frozen = true;
  assert.deepEqual((await run(c, k)).calls, []);
  c.vaults[ETH].frozen = false;
  assert.deepEqual((await run(c, k)).calls, ['k0:unpauseDeposits:eth', 'k0:pokeBorrow']);
});

test('a restarted keeper keeps the stop in the band and finds its old pause on-chain', async () => {
  const c = chain([ETH]);
  c.vaults[ETH].deficit = 60n;
  await run(c, keeper(c, KEEPER0, 0));
  // the pause sinks far below the reorg margin and several log chunks
  c.block += 3n * LOG_CHUNK_BLOCKS;
  c.vaults[ETH].deficit = 40n;
  const restarted = keeper(c, KEEPER0, 0);
  const band = await run(c, restarted);
  assert.deepEqual(band.calls, [], 'no ramp and no unpause in the band after a restart');
  assert.ok(band.alerts.some(a => a.includes('deficit stop')), 'the active stop is announced on start');
  c.vaults[ETH].deficit = 0n;
  assert.deepEqual((await run(c, keeper(c, KEEPER0, 0))).calls, ['k0:unpauseDeposits:eth', 'k0:pokeBorrow']);
});

test('two instances: one pause between them, and either can reopen the other\'s pause on its duty slot', async () => {
  const c = chain([ETH]);
  const k0 = keeper(c, KEEPER0, 0), k1 = keeper(c, KEEPER1, 1);
  c.vaults[ETH].deficit = 60n;
  assert.deepEqual((await run(c, k0, false)).calls, ['k0:pauseDeposits:eth']);
  assert.deepEqual((await run(c, k1, true)).calls, [], 'the second instance sees the pause and adds nothing');
  c.vaults[ETH].deficit = 10n;
  assert.deepEqual((await run(c, k0, false)).calls, [], 'reopening waits for the duty slot');
  assert.deepEqual((await run(c, k1, true)).calls, ['k1:unpauseDeposits:eth', 'k1:pokeBorrow']);
  assert.equal(c.vaults[ETH].depositsPaused, false);
  assert.deepEqual((await run(c, k0, true)).calls, ['k0:pokeBorrow'], 'the paused instance does not flap back');
});

test('an unreadable or unallocated view holds the ramp without pausing', async () => {
  const c = chain([ETH]);
  const k = keeper(c, KEEPER0, 0);
  c.carry = new Error('rpc down');
  const down = await run(c, k);
  assert.deepEqual(down.calls, []);
  assert.ok(down.alerts.some(a => a.includes('source deficit read failed')));
  c.carry = 0n;
  // stale active cash during allocation must not pause; pokeSettle comes first
  c.vaults[ETH].unallocated = true;
  c.vaults[ETH].deficit = 80n;
  const stale = await run(c, k);
  assert.ok(!stale.calls.some(x => x.includes('Deposits')));
  assert.ok(!stale.calls.includes('k0:pokeBorrow'));
  // a source stop needs no vault view
  c.carry = 70n;
  assert.ok((await run(c, k)).calls.includes('k0:pauseDeposits:eth'));
});

test('pause evidence survives a reorg of its newest blocks by searching again', async () => {
  const at = (block: bigint): EvidenceLog => ({block, index: 0, topics: [], data: '0x', tx: '0x'});
  let logs = [at(10n), at(95n)];
  const newest = (from: bigint, to: bigint) =>
    newestInChunks(async (lo, hi) => logs.filter(l => l.block >= lo && l.block <= hi), from, to);
  const tracker = new LatestLog(1_000n);
  assert.equal((await tracker.find(newest, 100n))?.block, 95n);
  logs = [at(10n)];
  assert.equal((await tracker.find(newest, 101n))?.block, 10n, 'a vanished recent log is not trusted');
  logs.push(at(99n + REORG_MARGIN_BLOCKS));
  assert.equal((await tracker.find(newest, 200n))?.block, 99n + REORG_MARGIN_BLOCKS);
  assert.equal((await new LatestLog(50n).find(newest, 1_000n)), undefined, 'the lookback bounds the search');
});
