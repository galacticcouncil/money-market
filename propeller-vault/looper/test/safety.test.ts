import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG, ROUNDING_POLICIES } from '../src/config.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const VAULT = '0x0000000000000000000000000000000000000002';
const OTHER = '0x0000000000000000000000000000000000000003';
const TARGET = 1050000000000000000n;

async function cycle(overrides: Record<string, bigint | boolean | string> = {}, multiple = false, harvest = false) {
  const calls: string[] = [];
  // Replace IO on the real scheduler; no RPC, wallets or transaction simulation.
  const keeper = Object.create(PropellerLooper.prototype) as any;
  Object.assign(keeper, { cycle: 0, subLoop: LOOP, vaults: multiple ? [VAULT, OTHER] : [VAULT], harvester: harvest ? OTHER : '', pool: '' });
  const state: Record<string, bigint | boolean | string> = {
    healthFactor: TARGET, targetHf: TARGET, unwindTargetEquity: 0n,
    deleverDebtTarget: 0n, paused: false, emergencyPaused: false, vaultPaused: false,
    queueHead: 0n, queueTail: 0n, queueUnwind: 0n, unwindEligibleAt: 100n,
    deleverTarget: 0n, reinvestAssets: 0n, availableHollar: 0n, mainDebt: OTHER, ready: true, pendingUnwindOf: 0n, harvestable: false, ...overrides,
  };
  keeper.read = async (_abi: unknown, _address: string, fn: string) => {
    if (state.failRead === fn) throw new Error('monitor unavailable');
    assert.ok(fn in state, `unexpected read ${fn}`);
    if (fn === 'paused' && _address !== LOOP) return state.vaultPaused || state.emergencyPaused;
    return state[fn];
  };
  keeper.blockTimestamp = async () => 100n;
  keeper.readLeverage = async () => null;
  keeper.poke = async (_abi: unknown, address: string, fn: string, _label: string, args: unknown[]) => {
    if (fn === 'maintainPeg') return false; // real poke filters a zero-work peg simulation
    if (fn === 'startUnwinds') assert.deepEqual(args, [8n], 'native-tested start batch fits the keeper budget');
    calls.push(`${address}:${fn}`); return true;
  };
  await keeper.runCycle();
  return calls;
}

test('low HF schedules and services safety repayment without user redemptions', async () => {
  assert.deepEqual(await cycle({ healthFactor: TARGET - 1n }), [`${LOOP}:deLever`, `${LOOP}:pokeRepay`]);
});
test('an existing safety target is serviced even if HF recovered', async () => {
  assert.deepEqual(await cycle({ deleverDebtTarget: 1n }), [`${LOOP}:pokeRepay`]);
});
test('Main down-rebalance is settled with an empty redemption queue', async () => {
  assert.deepEqual(await cycle({ deleverTarget: 1n }), [`${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`]);
});
test('active exits prevent ramping and share a single source repayment', async () => {
  assert.deepEqual(await cycle({ healthFactor: 2n * TARGET, queueTail: 1n, queueUnwind: 1n }, true), [
    `${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`, `${OTHER}:pokeSettle`,
  ]);
});
test('source pause stops swaps but not settlement of already freed funds', async () => {
  assert.deepEqual(await cycle({ paused: true, deleverTarget: 1n }), [`${VAULT}:pokeSettle`]);
});
test('idle healthy loop ramps normally', async () => {
  assert.deepEqual(await cycle({ healthFactor: 2n * TARGET }), [`${LOOP}:pokeBorrow`]);
});
test('unfunded operating buffer blocks ramp but not repayment', async () => {
  assert.deepEqual(await cycle({ healthFactor: 2n * TARGET, ready: false }), []);
  assert.deepEqual(await cycle({ ready: false, deleverTarget: 1n }), [`${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`]);
});
test('late source recoveries are pulled even after collateral exits completed', async () => {
  assert.deepEqual(await cycle({ pendingUnwindOf: 1n }), [`${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`]);
});
test('idle recovery surplus is not a repayment obligation', async () => {
  assert.deepEqual(await cycle({ healthFactor: 2n * TARGET, availableHollar: 100n }), [`${LOOP}:pokeBorrow`]);
});

test('cooldown-only requests do not start source repayment or ramping', async () => {
  assert.deepEqual(await cycle({ healthFactor: 2n * TARGET, queueTail: 1n, unwindEligibleAt: 101n }), []);
});
test('eligible requests start before a single source repayment and settlement', async () => {
  assert.deepEqual(await cycle({ queueTail: 1n }, true), [
    `${VAULT}:startUnwinds`, `${OTHER}:startUnwinds`, `${LOOP}:pokeRepay`,
    `${VAULT}:pokeSettle`, `${OTHER}:pokeSettle`,
  ]);
});
test('local vault freeze prevents starts, FIFO settlement and new ramping', async () => {
  assert.deepEqual(await cycle({ vaultPaused: true, queueTail: 2n, queueUnwind: 1n, healthFactor: 2n * TARGET }), []);
});
test('emergency freeze stops existing exit servicing without a safety target', async () => {
  assert.deepEqual(await cycle({ emergencyPaused: true, queueTail: 1n, queueUnwind: 1n, unwindTargetEquity: 100n }), []);
});
test('source emergency preserves safety repayment and Main committed repayment', async () => {
  assert.deepEqual(await cycle({ emergencyPaused: true, healthFactor: TARGET - 1n, deleverTarget: 1n, queueTail: 1n }), [
    `${LOOP}:deLever`, `${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`,
  ]);
});
test('source swap pause postpones starting otherwise eligible unwinds', async () => {
  assert.deepEqual(await cycle({ paused: true, queueTail: 1n }), []);
});

test('rounding monitor read failure alerts without blocking debt service', async () => {
  const errors: unknown[][] = [];
  const previous = console.error;
  ROUNDING_POLICIES.set(VAULT, {vault:VAULT,assetId:34,minimum:100n,target:200n});
  console.error = (...args) => { errors.push(args); };
  try {
    assert.deepEqual(await cycle({deleverTarget:1n}), [`${LOOP}:pokeRepay`, `${VAULT}:pokeSettle`]);
    assert.ok(errors.some(e=>String(e).includes('rounding monitor failed')));
  } finally { console.error=previous; ROUNDING_POLICIES.delete(VAULT); }
});

test('harvest precedes optional ramp and reinvests in the same maintenance cycle', async () => {
  assert.deepEqual(await cycle({ harvestable: true, healthFactor: 2n * TARGET }, false, true), [
    `${OTHER}:harvest`, `${VAULT}:rebalance`, `${VAULT}:pokeSettle`,
  ]);
});
test('empty harvests do not submit transactions or trigger extra maintenance', async () => {
  assert.deepEqual(await cycle({ harvestable: false }, false, true), []);
});

test('pending collateral deploys first and extra leverage waits for refreshed backing next cycle', async () => {
  assert.deepEqual(await cycle({reinvestAssets: 1n, healthFactor: 2n * TARGET}), [
    `${VAULT}:rebalance`,
  ]);
  assert.deepEqual(await cycle({reinvestAssets: 1n, queueTail: 1n, unwindEligibleAt: 101n}), []);
  assert.deepEqual(await cycle({reinvestAssets: 1n, emergencyPaused: true}), []);
});
test('harvest availability never bypasses emergency or local pause', async () => {
  assert.deepEqual(await cycle({ harvestable: true, emergencyPaused: true }, false, true), []);
  assert.deepEqual(await cycle({ harvestable: true, vaultPaused: true }, false, true), []);
});

test('a standby operator still acts on safety repayment while postponing optional ramp', async () => {
  const [count, index] = [CONFIG.OPERATOR_COUNT, CONFIG.OPERATOR_INDEX];
  CONFIG.OPERATOR_COUNT = 2;
  CONFIG.OPERATOR_INDEX = 0; // timestamp 100 is operator 1's slot
  try {
    assert.deepEqual(await cycle({healthFactor: 2n * TARGET}), []);
    assert.deepEqual(await cycle({healthFactor: TARGET - 1n}), [`${LOOP}:deLever`, `${LOOP}:pokeRepay`]);
  } finally { CONFIG.OPERATOR_COUNT = count; CONFIG.OPERATOR_INDEX = index; }
});

test('a broken vault queue monitor cannot prevent source safety repayment', async () => {
  assert.deepEqual(await cycle({healthFactor: TARGET - 1n, failRead: 'queueHead'}), [`${LOOP}:deLever`, `${LOOP}:pokeRepay`]);
  assert.deepEqual(await cycle({healthFactor: TARGET * 2n, failRead: 'queueHead'}), []);
});
