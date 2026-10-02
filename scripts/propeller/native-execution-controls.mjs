// Local-only acceptance of quote envelopes, shared budgets and the real keeper.
// Reuses the explicitly funded native campaign fixture; this is not APY evidence.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {artifact, artifactDir, artifactManifest, maxTransactionGas} from './native-artifacts.mjs';
const require = createRequire(import.meta.url);
const {ApiPromise, WsProvider} = require('@polkadot/api');
const {createPublicClient, createWalletClient, http, parseAbi, encodeFunctionData, encodeDeployData, keccak256, stringToHex} = require('viem');
const {privateKeyToAccount} = require('viem/accounts');
const input = JSON.parse(readFileSync(process.argv[2]));
const output = process.argv[3];
const port = Number(process.env.PROPELLER_LOCAL_PORT);
assert.ok(Number.isInteger(port) && port > 0 && port < 65536 && output);
const rpc = `http://127.0.0.1:${port}`;
assert.equal(input.rpc, rpc);
assert.equal(input.status, 'native-multi-user-multi-vault-campaign-passed');
const result = existsSync(output) ? JSON.parse(readFileSync(output)) : {rpc, fork: input.fork, calls: [], checks: {}};
assert.equal(result.rpc, rpc);
const save = () => {
  result.build = {artifactDir, artifacts: {...result.build?.artifacts, ...artifactManifest}};
  writeFileSync(output, JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
};
const key = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // public local dev account
const account = privateKeyToAccount(key);
const chain = {id: input.fork.chainId, name: 'Local controls acceptance', nativeCurrency: {name: 'WETH', symbol: 'WETH', decimals: 18}, rpcUrls: {default: {http: [rpc]}}};
const pub = createPublicClient({chain, transport: http(rpc, {timeout: 180000}), pollingInterval: 1000, cacheTime: 0});
// Chopsticks 2.3 exposes millisecond timestamps and Substrate block hashes
// through eth_getBlockByNumber. EVM quotes need seconds and ethereum.blockHash.
// Normalize this local adapter, never chain state or production quote checks.
const getBlock = pub.getBlock.bind(pub);
pub.getBlock = async options => {
  const block = await getBlock(options);
  assert.ok(block.timestamp >= 1_000_000_000_000n, 'unexpected local RPC timestamp unit');
  const hash = (await api.query.ethereum.blockHash(block.number.toString())).toHex();
  assert.notEqual(hash, '0x' + '0'.repeat(64), 'missing canonical EVM block hash');
  return {...block, hash, timestamp: block.timestamp / 1000n};
};
const wallet = createWalletClient({chain, account, transport: http(rpc, {timeout: 180000})});
const ws = new WsProvider(`ws://127.0.0.1:${port}`, 2500, {}, 180000);
const api = await ApiPromise.create({provider: ws, noInitWarn: true});
const {source, vault, tbtcVault, fees} = input.addresses;
let harvester = input.addresses.harvester;
const {hollar, prime, collateral, aPrime, hollarDebt, pool} = input.market;
const tokenAbi = parseAbi(['function approve(address,uint256) returns(bool)', 'function balanceOf(address) view returns(uint256)', 'function scaledBalanceOf(address) view returns(uint256)']);
const read = (address, abi, functionName, args = []) => pub.readContract({address, abi, functionName, args});
const vr = (address, fn, args = []) => read(address, artifact('CollateralVault').abi, fn, args);
const cr = (fn, args = []) => read(result.controller, artifact('ExecutionController').abi, fn, args);
async function estimate(request) {
  let high = request.gas ?? maxTransactionGas, low = 21000n;
  await pub.simulateContract({...request, gas: high});
  while (high - low > high / 10n) {
    const mid = (high + low) / 2n;
    try { await pub.simulateContract({...request, gas: mid}); high = mid; }
    catch (e) {
      let cause = e, reverted = false;
      while (cause) { reverted ||= cause.name === 'ExecutionRevertedError' || cause.code === 3; cause = cause.cause; }
      if (!reverted) throw e;
      low = mid;
    }
  }
  return high;
}
async function send(label, address, abi, functionName, args = []) {
  if (result.calls.some(c => c.label === label && c.status === 'success')) return;
  const gasPrice = (await pub.getGasPrice()) * 2n;
  const measured = await estimate({account, address, abi, functionName, args, gas: maxTransactionGas, gasPrice});
  const gas = (measured * 120n + 99n) / 100n;
  assert.ok(gas <= maxTransactionGas, `${label}: allowance exceeds native cap`);
  let hash;
  for (let attempt = 0; ; ++attempt) {
    try { hash = await wallet.writeContract({address, abi, functionName, args, gas, gasPrice: gasPrice + BigInt(attempt), type: 'legacy'}); break; }
    catch (e) { if (attempt >= 3 || !String(e).includes('Expected input with 32 bytes')) throw e; }
  }
  const receipt = await pub.waitForTransactionReceipt({hash, timeout: 240000});
  result.calls.push({label, hash, measured, gas, gasUsed: receipt.gasUsed, status: receipt.status}); save();
  assert.equal(receipt.status, 'success', label);
  console.log(label, receipt.gasUsed.toString());
}
async function deploy(name, args, key) {
  if (result[key]) return result[key];
  const art = artifact(name);
  const gasPrice = (await pub.getGasPrice()) * 2n;
  const data = encodeDeployData({abi: art.abi, bytecode: art.bytecode.object, args});
  const estimatedGas = await pub.estimateGas({account, data, gas: maxTransactionGas, gasPrice});
  const gas = (estimatedGas * 110n + 99n) / 100n;
  assert.ok(gas <= maxTransactionGas, `${name}: creation plus 10% margin exceeds native cap`);
  // Deployment size and receipts are independently recorded; no limits relaxed.
  let hash;
  for (let attempt = 0; ; ++attempt) {
    try { hash = await wallet.deployContract({abi: art.abi, bytecode: art.bytecode.object, args, gas, gasPrice: gasPrice + BigInt(attempt), type: 'legacy'}); break; }
    catch (e) { if (attempt >= 3 || !String(e).includes('Expected input with 32 bytes')) throw e; }
  }
  const receipt = await pub.waitForTransactionReceipt({hash, timeout: 240000});
  assert.equal(receipt.status, 'success', name);
  result[key] = receipt.contractAddress;
  result.deployments ??= [];
  result.deployments.push({name, address: receipt.contractAddress, estimatedGas, gasUsed: receipt.gasUsed, gasLimit: gas,
    codeHash: keccak256(await pub.getBytecode({address: receipt.contractAddress}))}); save();
  return receipt.contractAddress;
}
async function fingerprint() {
  return Promise.all([
    vr(vault, 'totalSupply'), vr(vault, 'syntheticSupplied'),
    read(hollarDebt, tokenAbi, 'scaledBalanceOf', [vault]),
    read(aPrime, tokenAbi, 'scaledBalanceOf', [source]),
    read(collateral, tokenAbi, 'balanceOf', [account.address]),
    read(source, artifact('SubLoop').abi, 'principalEquity'),
  ]);
}
try {
  await ws.send('dev_setBlockBuildMode', ['Instant']);
  // Refresh the mutable implementations and Harvester to the final artifacts
  // before exercising the controller against the funded local campaign.
  const implementation = await deploy('SubLoop', [], 'sourceImplementation');
  await send('source.currentImplementation', source, artifact('SubLoop').abi, 'upgradeTo', [implementation]);
  const vaultImplementation = await deploy('CollateralVault', [], 'vaultImplementation');
  for (const v of [vault, tbtcVault]) await send(`vault.currentImplementation.${v}`, v, artifact('CollateralVault').abi, 'upgradeTo', [vaultImplementation]);
  harvester = await deploy('Harvester', [source, prime, account.address], 'harvester');
  await send('harvester.fees', harvester, artifact('Harvester').abi, 'setFeeController', [fees]);
  await send('source.harvester', source, artifact('SubLoop').abi, 'setHarvester', [harvester]);
  for (const v of [vault, tbtcVault]) {
    await send(`harvester.vault.${v}`, harvester, artifact('Harvester').abi, 'addVault', [v]);
    await send(`fees.harvester.${v}`, fees, artifact('PropellerFeeController').abi, 'registerVault', [v, harvester]);
  }
  await deploy('ExecutionController', [account.address, 60n, 5n], 'controller');
  const ctl = artifact('ExecutionController').abi;
  const entry = keccak256(stringToHex('entry')), harvest = keccak256(stringToHex('harvest'));
  const previousExpiry = result.expiry && BigInt(result.expiry);
  const expiry = previousExpiry && previousExpiry < 1_000_000_000_000n ? previousExpiry
    : (await pub.getBlock()).timestamp + 30n * 86400n;
  result.expiry = expiry.toString(); save();
  await send(`entryBudget.${expiry}`, result.controller, ctl, 'configureBudget', [entry, hollar, 5000n * 10n ** 18n, 0n, expiry]);
  await send(`harvestBudget.${expiry}`, result.controller, ctl, 'configureBudget', [harvest, prime, 100n * 10n ** 6n, 0n, expiry]);
  await send('entryLimit', result.controller, ctl, 'configureLimit', [source, hollar, aPrime, entry, 10n * 10n ** 18n, 1000n * 10n ** 18n]);
  const actions = [[source, 'SubLoop', 'pokeBorrow', []], [harvester, 'Harvester', 'harvest', [[]]]];
  for (const v of [vault, tbtcVault]) {
    const asset = await vr(v, 'asset'), ledger = await vr(v, 'mainDebt');
    const decimals = await read(asset, parseAbi(['function decimals() view returns(uint8)']), 'decimals');
    const unit = 10n ** BigInt(decimals);
    const group = keccak256(stringToHex(`service:${v}`));
    await send(`serviceBudget.${v}.${expiry}`, result.controller, ctl, 'configureBudget', [group, asset, unit, 0n, expiry]);
    await send(`serviceLimit.${v}`, result.controller, ctl, 'configureLimit', [ledger, asset, hollar, group, 1n, unit]);
    await send(`harvestLimit.${v}`, result.controller, ctl, 'configureLimit', [v, prime, asset, harvest, 1n * 10n ** 6n, 50n * 10n ** 6n]);
    actions.push([v, 'CollateralVault', 'deposit', [1n, account.address]], [v, 'CollateralVault', 'rebalance', []]);
    await send(`bind.${v}`, v, artifact('CollateralVault').abi, 'setExecutionController', [result.controller]);
  }
  for (const [target, name, fn, args] of actions) {
    const selector = encodeFunctionData({abi: artifact(name).abi, functionName: fn, args}).slice(0, 10);
    await send(`action.${target}.${fn}`, result.controller, ctl, 'configureAction', [target, selector, true]);
  }
  await send('bind.source', source, artifact('SubLoop').abi, 'setExecutionController', [result.controller]);
  await send('bind.harvester', harvester, artifact('Harvester').abi, 'setExecutionController', [result.controller]);
  // Dedicated income fixture supports losses/interest and a bounded backlog.
  const poolAbi = JSON.parse(readFileSync(new URL('../../deployments/hydration/Pool-Implementation.json', import.meta.url))).abi;
  await send('income.approve', prime, tokenAbi, 'approve', [pool, 1000n * 10n ** 6n]);
  await send('income.supply', pool, poolAbi, 'supply', [prime, 1000n * 10n ** 6n, source, 0]);
  await send('deposit.approve', collateral, tokenAbi, 'approve', [vault, 10n ** 18n]);
  const data = encodeFunctionData({abi: artifact('CollateralVault').abi, functionName: 'deposit', args: [5n * 10n ** 16n, account.address]});
  if (!result.checks.previewRollback) {
    const before = await fingerprint();
    await send('minedPreview', result.controller, ctl, 'preview', [vault, data]);
    assert.deepEqual(await fingerprint(), before, 'native side effects escaped the preview revert');
    result.checks.previewRollback = true; save();
  }
  process.env.RPC_URL = rpc;
  process.env.RPC_URLS = rpc;
  process.env.LOOPER_PRIVATE_KEY = key;
  process.env.SUBLOOP_ADDRESS = source;
  process.env.VAULT_ADDRESSES = [vault, tbtcVault].join(',');
  process.env.HARVESTER_ADDRESS = harvester;
  process.env.POOL_ADDRESS = pool;
  process.env.GAS_ASSET_ADDRESS = collateral;
  process.env.EXECUTION_CONTROLLER = result.controller;
  process.env.PROPELLER_ROUNDING_RESERVES = JSON.stringify(input.roundingPolicies);
  const {PropellerLooper} = await import('../../propeller-vault/looper/dist/looper.js');
  const keeper = new PropellerLooper();
  const keeperGetBlock = keeper.publicClient.getBlock.bind(keeper.publicClient);
  keeper.publicClient.getBlock = async options => {
    const block = await keeperGetBlock(options);
    assert.ok(block.timestamp >= 1_000_000_000_000n);
    const hash = (await api.query.ethereum.blockHash(block.number.toString())).toHex();
    assert.notEqual(hash, '0x' + '0'.repeat(64));
    return {...block, hash, timestamp: block.timestamp / 1000n};
  };
  keeper.publicClient.estimateContractGas = estimate;
  const economicCheck = keeper.harvestWorthwhile.bind(keeper);
  keeper.harvestWorthwhile = async (primeAmount, gasWei, now) => {
    const execute = await economicCheck(primeAmount, gasWei, now);
    result.economics ??= [];
    result.economics.push({primeAmount, gasWei, timestamp: now, execute}); save();
    return execute;
  };
  const original = keeper.walletClient.writeContract.bind(keeper.walletClient);
  keeper.walletClient.writeContract = async request => {
    let hash;
    for (let attempt = 0; ; ++attempt) {
      try { hash = await original({...request, gasPrice: request.gasPrice + BigInt(attempt)}); break; }
      catch (e) { if (attempt >= 3 || !String(e).includes('Expected input with 32 bytes')) throw e; }
    }
    result.keeperSubmissions ??= [];
    result.keeperSubmissions.push({hash, functionName: request.functionName, gas: request.gas, args: request.args}); save();
    return hash;
  };
  const receipt = keeper.publicClient.waitForTransactionReceipt.bind(keeper.publicClient);
  keeper.publicClient.waitForTransactionReceipt = async request => {
    const value = await receipt(request);
    Object.assign(result.keeperSubmissions.find(s => s.hash === request.hash), {status: value.status, gasUsed: value.gasUsed}); save();
    return value;
  };
  if (!result.checks.quotedDeposit) {
    const block = await pub.getBlock({blockNumber: (await pub.getBlockNumber()) - 1n});
    const preview = await pub.simulateContract({account, address: result.controller, abi: ctl, functionName: 'preview', args: [vault, data], blockNumber: block.number, gas: maxTransactionGas});
    const quotes = preview.result[1].map(t => ({lane: t.lane, amountIn: t.amountIn, minOut: t.amountOut * 9998n / 10000n}));
    await send('quotedDeposit', result.controller, ctl, 'execute', [vault, data, block.number, block.hash, block.timestamp + 60n, quotes]);
    result.checks.quotedDeposit = true; save();
  }
  if (!result.checks.boundedHarvest) {
    if (!result.checks.uneconomicalHarvestNoTransaction) {
      const submissions = result.keeperSubmissions?.length ?? 0;
      assert.equal(await keeper.poke(artifact('Harvester').abi, harvester, 'harvest', 'small native harvest', [[]]), false);
      assert.equal(result.economics.at(-1).execute, false, 'skip must come from the economic policy');
      assert.equal(result.keeperSubmissions?.length ?? 0, submissions);
      result.checks.uneconomicalHarvestNoTransaction = true; save();
    }
    // The measured 100-PRIME batch costs more than the default 10bp gas budget.
    // Test a reviewed local 200-PRIME batch, preserving the keeper cost rule,
    // oracle floors and quote tolerances. This is not a production size choice.
    const batched = keccak256(stringToHex('harvest-batched'));
    await send('batchedHarvestBudget', result.controller, ctl, 'configureBudget', [batched, prime, 200n * 10n ** 6n, 0n, expiry]);
    for (const v of [vault, tbtcVault]) {
      await send(`batchedHarvestLimit.${v}`, result.controller, ctl, 'configureLimit',
        [v, prime, await vr(v, 'asset'), batched, 1n * 10n ** 6n, 100n * 10n ** 6n]);
    }
    // Ensure the quote's parent block already contains the complete policy.
    await ws.send('dev_newBlock', [{count: 1}]);
    const before = await cr('available', [vault, prime, collateral]);
    assert.equal(await keeper.poke(artifact('Harvester').abi, harvester, 'harvest', 'bounded native harvest', [[]]), true);
    const after = await cr('available', [vault, prime, collateral]);
    assert.ok(after < before, 'harvest did not consume the shared PRIME budget');
    result.checks.boundedHarvest = true; save();
  }
  const submissions = result.keeperSubmissions?.length ?? 0;
  assert.equal(await keeper.poke(artifact('CollateralVault').abi, vault, 'maintainPeg', 'idle native peg'), false);
  assert.equal(result.keeperSubmissions?.length ?? 0, submissions);
  result.checks.idlePegNoTransaction = true;
  const tooLarge = encodeFunctionData({abi: artifact('CollateralVault').abi, functionName: 'deposit', args: [1n * 10n ** 18n, account.address]});
  await send('oversized.approve', collateral, tokenAbi, 'approve', [vault, 10n ** 18n]);
  // Chopsticks may return the raw error selector rather than decoded ABI data.
  await assert.rejects(() => pub.simulateContract({account, address: result.controller, abi: ctl, functionName: 'preview', args: [vault, tooLarge], gas: maxTransactionGas}), /TradeSize|0x1f5d0c4f/);
  result.checks.oversizedDepositRejected = true;
  result.status = 'native-execution-controls-passed';
  delete result.error;
  result.limitations = ['Local native runtime 447, not a production activation', 'Campaign and 1000 PRIME donated-income fixture; no organic APY claim', 'Test budgets are not approved production liquidity limits', 'Source/vault implementations and Harvester refreshed locally to the final artifacts', 'Local RPC timestamps normalized to EVM seconds and block hashes read from ethereum.blockHash; local gas estimates use bounded eth_call search'];
  save();
} catch (error) {
  result.status = 'failed'; result.error = error.stack ?? String(error); save(); console.error(error); process.exitCode = 1;
} finally { await api.disconnect(); }
