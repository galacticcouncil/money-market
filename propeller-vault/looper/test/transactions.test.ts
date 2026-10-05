import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PropellerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import {encodeAbiParameters, parseAbi, toHex} from 'viem';

const VAULT = '0x0000000000000000000000000000000000000002';
const SETTLE_ABI = parseAbi(['function pokeSettle() returns (uint256)']);

test('a mismatched controller rejects the entire harvest before previewing any swaps', async () => {
  const previous = CONFIG.EXECUTION_CONTROLLER;
  CONFIG.EXECUTION_CONTROLLER = VAULT;
  const other = '0x0000000000000000000000000000000000000004';
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = {address: VAULT};
  keeper.subLoop = VAULT;
  keeper.vaults = [other];
  keeper.publicClient = {
    readContract: async (r: any) => {
      assert.equal(r.blockNumber, 99n);
      return r.address === other ? other : VAULT;
    },
    simulateContract: async () => assert.fail('must not preview an unprotected route'),
  };
  try {
    await assert.rejects(() => keeper.quoteAction(VAULT, '0x12345678', 'harvest', 99n, 16000000n), /controller mismatch/);
  } finally { CONFIG.EXECUTION_CONTROLLER = previous; }
});

test('operator-funded gas cannot suppress a price-safe harvest and needs no gas oracle', async () => {
  const previous = CONFIG.SPONSORED_GAS;
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.subLoop = VAULT;
  keeper.pool = VAULT;
  keeper.harvester = VAULT;
  keeper.vaults = [];
  const reads: string[] = [];
  keeper.read = async (_abi: unknown, _address: string, method: string, args?: string[]) => {
    reads.push(method);
    if (method === 'prime' || method === 'ADDRESSES_PROVIDER' || method === 'getPriceOracle') return VAULT;
    if (method === 'getAssetPrice') {
      if (args?.[0] === VAULT) return 100000000n;
      assert.equal(CONFIG.SPONSORED_GAS, false, 'sponsored mode must not read the gas oracle');
      return 3000n * 100000000n;
    }
    if (method === 'decimals') return 6;
    if (method === 'lastHarvestAt') return 100n;
    assert.fail(method);
  };
  try {
    CONFIG.SPONSORED_GAS = true;
    assert.equal(await keeper.harvestWorthwhile(10000000n, 10n ** 18n, 101n), true);
    assert.equal(reads.filter(r => r === 'getAssetPrice').length, 1);
    CONFIG.SPONSORED_GAS = false;
    assert.equal(await keeper.harvestWorthwhile(10000000n, 10n ** 18n, 101n), false);
  } finally { CONFIG.SPONSORED_GAS = previous; }
});

async function poke(estimate: bigint, blockGas = 45_000_000n, status = 'success', estimateFails = false, result?: bigint, finalFails = false) {
  const sends: any[] = [], simulations: any[] = [];
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = { address: VAULT };
  keeper.publicClient = {
    getBlock: async () => ({ gasLimit: blockGas }),
    getGasPrice: async () => 4_613_433n,
    getTransactionCount: async () => 0,
    simulateContract: async (request: any) => {
      simulations.push(request);
      if (finalFails && simulations.length === 2) throw new Error('out of gas at submitted allowance');
      return { request, result };
    },
    request: async (r: any) => {
      assert.equal(r.method, 'eth_estimateGas');
      const budget = [blockGas, CONFIG.MAX_TX_GAS, 16777216n].reduce((a, b) => a < b ? a : b);
      assert.equal(r.params[0].gas, toHex(budget * 100n / 120n));
      assert.equal(r.params[0].from, VAULT);
      if (estimateFails) throw new Error('estimation unavailable');
      return toHex(estimate);
    },
    waitForTransactionReceipt: async () => ({ status }),
  };
  keeper.walletClient = { writeContract: async (request: any) => { sends.push(request); return '0x123'; } };
  const success = await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle');
  return { success, sends, simulations, keeper };
}

test('cached pending nonces cannot reuse a mined maintenance nonce', async () => {
  const {keeper, sends} = await poke(100000n);
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), true);
  assert.deepEqual(sends.map((request: any) => request.nonce), [0, 1]);
  keeper.publicClient.getTransactionCount = async () => 7;
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), true);
  assert.equal(sends[2].nonce, 7);
});

test('shutdown refuses new work and cancels writes still awaiting their nonce', async () => {
  const {keeper, sends} = await poke(100000n);
  keeper.publicClient.getTransactionCount = async () => { keeper.stop(); return 1; };
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), false);
  assert.equal(sends.length, 1, 'shutdown during an RPC must prevent signing');
  keeper.publicClient.getBlock = async () => assert.fail('stopped keeper must not start work');
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), false);
  await keeper.runCycle();
});

test('shutdown drains a submitted transaction before releasing its signer lock', async () => {
  const {keeper, sends} = await poke(100000n);
  let finish!: (value: {status: string}) => void;
  let submitted!: () => void;
  const waiting = new Promise<void>(resolve => { submitted = resolve; });
  keeper.publicClient.waitForTransactionReceipt = () => {
    submitted();
    return new Promise(resolve => { finish = resolve; });
  };
  const inFlight = keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle');
  await waiting;
  keeper.stop();
  assert.equal(keeper.receiptPending, true);
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), false);
  assert.equal(sends.length, 2);
  finish({status: 'success'});
  assert.equal(await inFlight, true);
  assert.equal(keeper.receiptPending, false);
});

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
test('an RPC gas result cannot bypass successful simulation at the submitted allowance', async () => {
  const {success, sends, simulations} = await poke(100000n, 45000000n, 'success', false, 1n, true);
  assert.equal(success, false);
  assert.equal(sends.length, 0);
  assert.equal(simulations[1].gas, 120000n);
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
  keeper.subLoop = VAULT;
  keeper.publicClient = {
    getBlock: async (o: any) => ({number: o.blockNumber ?? 10n, timestamp: 100n, gasLimit: 45_000_000n, hash}),
    getGasPrice: async () => 100n,
    getTransactionCount: async () => 0,
    readContract: async (r: any) => r.functionName === 'executionController' ? CONFIG.EXECUTION_CONTROLLER : r.functionName === 'available' ? 100n
      : r.functionName === 'limits' ? [lane, 100n, 100n] : r.functionName === 'lane' ? lane : VAULT,
    simulateContract: async (request: any) => {
      simulations.push(request);
      return {request, result: request.functionName === 'preview'
        ? [result, [{lane, amountIn: 100n, amountOut: 1000n}]] : result};
    },
    request: async () => toHex(100000n),
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
    getTransactionCount: async () => 0,
    simulateContract: async (request: any) => ({request, result: 1n}),
    request: async () => toHex(100000n),
    waitForTransactionReceipt: async () => { throw new Error('RPC disconnected'); },
  };
  keeper.walletClient = {writeContract: async () => { ++sends; return `0x${'ab'.repeat(32)}`; }};
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), false);
  assert.equal(await keeper.poke(SETTLE_ABI, VAULT, 'pokeSettle', 'settle'), false);
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
    readContract: async (r: any) => r.functionName === 'executionController' ? CONFIG.EXECUTION_CONTROLLER : r.functionName === 'available' ? 1000n
      : r.functionName === 'limits' ? [lane, 1n, 1000n] : r.functionName === 'lane' ? lane : VAULT,
    simulateContract: async (r: any) => {
      calls.push(r);
      if (r.functionName === 'preview') throw Object.assign(new Error('price floor'), {name: 'ContractFunctionRevertedError'});
      assert.equal(r.args[2][0].amountIn, 500n);
      assert.equal(r.blockNumber, 99n);
      return {result: [encodeAbiParameters([{type: 'uint256'}], [1n]), []]};
    },
  };
  try {
    assert.deepEqual(await keeper.quoteAction(VAULT, '0x12345678', 'pokeBorrow', 99n, 16000000n), [encodeAbiParameters([{type: 'uint256'}], [1n]), []]);
    assert.equal(calls.length, 2);
    keeper.publicClient.simulateContract = async () => { throw new Error('RPC offline'); };
    keeper.publicClient.readContract = async (r: any) => {
      if (r.functionName === 'executionController') return CONFIG.EXECUTION_CONTROLLER;
      assert.fail('RPC failure must not be mistaken for an oversized trade');
    };
    await assert.rejects(() => keeper.quoteAction(VAULT, '0x12345678', 'pokeBorrow', 99n, 16000000n), /RPC offline/);
  } finally { CONFIG.EXECUTION_CONTROLLER = previous; }
});

test('an executable large quote is still compared with smaller, better-priced slices', async () => {
  const previous = CONFIG.EXECUTION_CONTROLLER;
  CONFIG.EXECUTION_CONTROLLER = VAULT;
  const keeper = Object.create(PropellerLooper.prototype) as any;
  keeper.account = {address: VAULT};
  keeper.subLoop = VAULT;
  keeper.vaults = [];
  const lane = `0x${'ab'.repeat(32)}`;
  const amounts: bigint[] = [];
  keeper.publicClient = {
    readContract: async (r: any) => {
      assert.equal(r.blockNumber, 99n);
      return r.functionName === 'executionController' ? CONFIG.EXECUTION_CONTROLLER : r.functionName === 'available' ? 1000n : r.functionName === 'limits' ? [lane, 10n, 1000n]
        : r.functionName === 'lane' ? lane : VAULT;
    },
    simulateContract: async (r: any) => {
      assert.equal(r.blockNumber, 99n);
      const amount = r.functionName === 'preview' ? 1000n : r.args[2][0].amountIn;
      amounts.push(amount);
      return {result: [encodeAbiParameters([{type: 'uint256'}], [amount]),
        [{lane, amountIn: amount, amountOut: amount === 1000n ? 999n : amount}]]};
    },
  };
  try {
  const [, fills] = await keeper.quoteAction(VAULT, '0x12345678', 'pokeBorrow', 99n, 16000000n);
  assert.equal(fills[0].amountIn, 500n, 'largest tested slice at the best unit price');
  assert.ok(amounts.length > 2, 'a successful first simulation does not end price discovery');
  assert.ok(amounts.every(a => a >= 10n), 'sizing never goes below the configured minimum');
  assert.ok(amounts.includes(10n), 'even large budgets sample the minimum within the bounded search');
  } finally { CONFIG.EXECUTION_CONTROLLER = previous; }
});
