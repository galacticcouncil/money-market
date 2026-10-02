import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';

const VAULT = '0x0000000000000000000000000000000000000002';

async function poke(estimate: bigint, blockGas = 45_000_000n, status = 'success', estimateFails = false) {
  const sends: any[] = [], simulations: any[] = [];
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = { address: VAULT };
  keeper.publicClient = {
    getBlock: async () => ({ gasLimit: blockGas }),
    getGasPrice: async () => 4_613_433n,
    simulateContract: async (request: any) => { simulations.push(request); return { request }; },
    estimateContractGas: async () => { if (estimateFails) throw new Error('estimation unavailable'); return estimate; },
    waitForTransactionReceipt: async () => ({ status }),
  };
  keeper.walletClient = { writeContract: async (request: any) => { sends.push(request); return '0x123'; } };
  const success = await keeper.poke([], VAULT, 'pokeSettle', 'settle');
  return { success, sends, simulations };
}

test('large settlement uses estimated gas and the live fee quote', async () => {
  const { success, sends } = await poke(7_372_545n);
  assert.equal(success, true);
  assert.equal(sends[0].gas, 8_847_054n);
  assert.equal(sends[0].gasPrice, 5_536_120n);
});
test('small operations only reserve their estimated gas plus margin', async () => {
  assert.equal((await poke(100_001n)).sends[0].gas, 120_002n);
});
test('an operator budget cannot be silently exceeded', async () => {
  const { success, sends, simulations } = await poke(CONFIG.MAX_TX_GAS);
  assert.equal(success, false);
  assert.equal(sends.length, 0);
  assert.equal(simulations[0].gas, CONFIG.MAX_TX_GAS);
});
test('the live chain limit also bounds the submission budget', async () => {
  const { success, sends, simulations } = await poke(7_372_545n, 8_000_000n);
  assert.equal(success, false);
  assert.equal(sends.length, 0);
  assert.equal(simulations[0].gas, 8_000_000n);
});
test('a larger operator budget cannot bypass the native per-transaction cap', async () => {
  const previous = CONFIG.MAX_TX_GAS;
  CONFIG.MAX_TX_GAS = 45_000_000n;
  try {
    const { success, sends, simulations } = await poke(14_344_272n);
    assert.equal(success, false);
    assert.equal(sends.length, 0);
    assert.equal(simulations[0].gas, 16_777_216n);
  } finally { CONFIG.MAX_TX_GAS = previous; }
});
test('estimation failure never falls back to a fixed gas limit', async () => {
  assert.equal((await poke(1n, 45_000_000n, 'success', true)).sends.length, 0);
});
test('a reverted receipt is not treated as successful maintenance', async () => {
  assert.equal((await poke(100_000n, 45_000_000n, 'reverted')).success, false);
});
