import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import {encodeAbiParameters, parseAbi} from 'viem';

const VAULT = '0x0000000000000000000000000000000000000002';

async function poke(estimate: bigint, blockGas = 45_000_000n, status = 'success', estimateFails = false, result?: bigint) {
  const sends: any[] = [], simulations: any[] = [];
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = { address: VAULT };
  keeper.publicClient = {
    getBlock: async () => ({ gasLimit: blockGas }),
    getGasPrice: async () => 4_613_433n,
    simulateContract: async (request: any) => { simulations.push(request); return { request, result }; },
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

test('a successful no-op simulation never becomes a paid transaction', async () => {
  const {success, sends} = await poke(1_400_000n, 45_000_000n, 'success', false, 0n);
  assert.equal(success, false);
  assert.equal(sends.length, 0);
});

test('guarded writes use a pinned preview, bounded input and positive quote floor', async () => {
  const previous = CONFIG.EXECUTION_CONTROLLER;
  CONFIG.EXECUTION_CONTROLLER = '0x0000000000000000000000000000000000000003';
  const sends: any[] = [], simulations: any[] = [];
  const keeper = Object.create(PropellerLooper.prototype) as any;
  const hash = `0x${'ab'.repeat(32)}`;
  const lane = `0x${'cd'.repeat(32)}`;
  const result = encodeAbiParameters([{type: 'uint256'}], [100n]);
  keeper.account = {address: VAULT};
  keeper.publicClient = {
    getBlock: async (o: any) => ({number: o.blockNumber ?? 10n, timestamp: 100n, gasLimit: 45_000_000n, hash}),
    getGasPrice: async () => 100n,
    simulateContract: async (request: any) => {
      simulations.push(request);
      return {request, result: request.functionName === 'preview'
        ? [result, [{lane, amountIn: 100n, amountOut: 1000n}]] : result};
    },
    estimateContractGas: async () => 100000n,
    waitForTransactionReceipt: async () => ({status: 'success'}),
  };
  keeper.walletClient = {writeContract: async (request: any) => { sends.push(request); return hash; }};
  try {
    assert.equal(await keeper.poke(parseAbi(['function pokeBorrow() returns (uint256)']), VAULT, 'pokeBorrow', 'ramp'), true);
    assert.equal(simulations[0].blockNumber, 9n);
    assert.equal(sends[0].address, CONFIG.EXECUTION_CONTROLLER);
    assert.equal(sends[0].functionName, 'execute');
    assert.deepEqual(sends[0].args.slice(2), [9n, hash, 160n, [{lane, amountIn: 100n, minOut: 999n}]]);
  } finally { CONFIG.EXECUTION_CONTROLLER = previous; }
});

test('a receipt RPC failure retains the signer lock instead of blindly sending another transaction', async () => {
  const keeper = Object.create(PropellerLooper.prototype) as any;
  let sends = 0;
  keeper.account = {address: VAULT};
  keeper.publicClient = {
    getBlock: async () => ({gasLimit: 45_000_000n}), getGasPrice: async () => 100n,
    simulateContract: async (request: any) => ({request, result: 1n}),
    estimateContractGas: async () => 100000n,
    waitForTransactionReceipt: async () => { throw new Error('RPC disconnected'); },
  };
  keeper.walletClient = {writeContract: async () => { ++sends; return `0x${'ab'.repeat(32)}`; }};
  assert.equal(await keeper.poke([], VAULT, 'pokeSettle', 'settle'), false);
  assert.equal(await keeper.poke([], VAULT, 'pokeSettle', 'settle'), false);
  assert.equal(sends, 1);
  assert.equal(keeper.receiptPending, true);
});

test('a rejected large quote is retried at a smaller input while RPC errors are not resized', async () => {
  const previous = CONFIG.EXECUTION_CONTROLLER;
  CONFIG.EXECUTION_CONTROLLER = VAULT;
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = {address: VAULT};
  keeper.subLoop = VAULT;
  keeper.vaults = [];
  const lane = `0x${'ab'.repeat(32)}`;
  const calls: any[] = [];
  keeper.publicClient = {
    readContract: async (r: any) => r.functionName === 'available' ? 1000n : r.functionName === 'lane' ? lane : VAULT,
    simulateContract: async (r: any) => {
      calls.push(r);
      if (r.functionName === 'preview') throw Object.assign(new Error('price floor'), {name: 'ContractFunctionRevertedError'});
      assert.equal(r.args[2][0].amountIn, 500n);
      assert.equal(r.blockNumber, 99n);
      return {result: ['0x01', []]};
    },
  };
  try {
    assert.deepEqual(await keeper.quoteAction(VAULT, '0x12345678', 'pokeBorrow', 99n, 16000000n), ['0x01', []]);
    assert.equal(calls.length, 2);
    keeper.publicClient.simulateContract = async () => { throw new Error('RPC offline'); };
    keeper.publicClient.readContract = async () => { assert.fail('RPC failure must not be mistaken for an oversized trade'); };
    await assert.rejects(() => keeper.quoteAction(VAULT, '0x12345678', 'pokeBorrow', 99n, 16000000n), /RPC offline/);
  } finally { CONFIG.EXECUTION_CONTROLLER = previous; }
});
