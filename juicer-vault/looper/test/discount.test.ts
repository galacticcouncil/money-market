import assert from 'node:assert/strict';
import {test} from 'node:test';
import {JuicerLooper} from '../src/looper.js';
import {CONFIG} from '../src/config.js';
import {discountDue, pendingDiscount} from '../src/discount-policy.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const VAULT = '0x0000000000000000000000000000000000000002';
const TOKEN = '0x0000000000000000000000000000000000000003';
const POOL = '0x0000000000000000000000000000000000000004';
const HOLLAR = '0x0000000000000000000000000000000000000005';
const U = 10n ** 18n, RAY = 10n ** 27n;

function fixture() {
  const keeper = Object.create(JuicerLooper.prototype) as any;
  const state: Record<string, any> = {hollar: HOLLAR, hollarDebtToken: TOKEN, principalEquity: 60_000n * U,
    scaledBalanceOf: 300_000n * U, balanceOf: 299_960n * U, getReserveNormalizedVariableDebt: RAY};
  Object.assign(keeper, {subLoop: LOOP, vaults: [VAULT], pool: POOL});
  const reads: string[] = [];
  keeper.read = async (_abi: unknown, address: string, name: string, args: any[] = []) => {
    reads.push(name);
    if (state.fail === name) throw new Error('rpc down');
    if (name === 'scaledBalanceOf' || name === 'balanceOf') assert.deepEqual([address, args], [TOKEN, [LOOP]]);
    if (name === 'getReserveNormalizedVariableDebt') assert.deepEqual([address, args], [POOL, [HOLLAR]]);
    assert(name in state, `unexpected read ${name}`);
    return state[name];
  };
  const calls: any[] = [];
  keeper.poke = async (...args: any[]) => { calls.push(args); return true; };
  return {keeper, state, calls, reads};
}

test('unsettled discount is the debt aave counts less the live balance', () => {
  // Hydration block 17,167,223: the loop's scaled balance, the HOLLAR index and its discounted balance
  assert.equal(pendingDiscount(287533793710041840995255n, 1054595954225753374676312108n, 303102338229679240614493n),
    129637320113258333339n);
  assert.equal(pendingDiscount(100n * U, RAY, 100n * U), 0n);
  assert.equal(pendingDiscount(100n * U, RAY, 101n * U), 0n, 'never negative');
  assert.equal(pendingDiscount(3n, RAY / 2n, 1n), 1n, 'rounds half up like rayMul');
  assert.equal(pendingDiscount(0n, RAY, 0n), 0n);
});

test('a settlement is due at the configured share of loop principal and never below the floor', () => {
  const principal = 60_000n * U, floor = U;
  assert.equal(discountDue(30n * U - 1n, principal, 5n, floor), false);
  assert.equal(discountDue(30n * U, principal, 5n, floor), true);
  assert.equal(discountDue(U - 1n, 100n * U, 5n, floor), false, 'a small loop waits for the floor');
  assert.equal(discountDue(U, 100n * U, 5n, floor), true);
  assert.equal(discountDue(10_000n * U, principal, 0n, floor), false, 'zero bps turns it off');
  assert.equal(discountDue(0n, 0n, 5n, 0n), false, 'nothing to burn');
});

test('the keeper burns a due discount through the debt token and leaves a small one alone', async () => {
  const {keeper, state, calls} = fixture();
  assert.equal(await keeper.settleLoopDiscount(), true);
  assert.equal(calls.length, 1);
  assert.deepEqual([calls[0][1], calls[0][2], calls[0][4]], [TOKEN, 'rebalanceUserDiscountPercent', [LOOP]]);
  assert.ok(!calls[0][5], 'not a controller-quoted call');
  state.balanceOf = 299_971n * U;
  assert.equal(await keeper.settleLoopDiscount(), false);
  assert.equal(calls.length, 1, '29 of 60,000 is under 5 bps');
  state.getReserveNormalizedVariableDebt = RAY + RAY / 100_000n;
  assert.equal(await keeper.settleLoopDiscount(), true, 'interest accrued since the last touch counts');
  assert.equal(calls.length, 2);
});

test('settling can be turned off, and an unreadable discount alerts once without stopping the cycle', async () => {
  const {keeper, state, calls, reads} = fixture();
  const [bps, error] = [CONFIG.LOOP_DISCOUNT_SETTLE_BPS, console.error];
  const alerts: string[] = [];
  console.error = (...args: unknown[]) => { alerts.push(args.join(' ')); };
  try {
    CONFIG.LOOP_DISCOUNT_SETTLE_BPS = 0n;
    assert.equal(await keeper.settleLoopDiscount(), false);
    assert.deepEqual([calls.length, reads.length], [0, 0]);
    CONFIG.LOOP_DISCOUNT_SETTLE_BPS = bps;
    state.fail = 'scaledBalanceOf';
    assert.equal(await keeper.settleLoopDiscount(), false);
    assert.equal(await keeper.settleLoopDiscount(), false);
    assert.deepEqual(alerts, ['[ALERT] loop discount unreadable; loop equity may lag its earnings: rpc down']);
    state.fail = undefined;
    assert.equal(await keeper.settleLoopDiscount(), true);
    state.fail = 'principalEquity';
    await keeper.settleLoopDiscount();
    assert.equal(alerts.length, 2, 'a recovered read re-arms the alert');
    assert.equal(calls.length, 1);
  } finally { CONFIG.LOOP_DISCOUNT_SETTLE_BPS = bps; console.error = error; }
});
