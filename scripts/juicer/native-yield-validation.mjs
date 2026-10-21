// Third-pass local-only validation. Uses public development keys, explicit
// donated income/recovery fixtures, the real keeper and native Aave execution.
// Next version: sync() allocates, and funded earnings sit in balanceOf (no claims).
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { artifact, maxTransactionGas } from './native-artifacts.mjs';
const require = createRequire(import.meta.url);
const { ApiPromise, WsProvider } = require('@polkadot/api');
const { u8aToHex } = require('@polkadot/util');
const { createPublicClient, createWalletClient, http, parseAbi, encodeDeployData, keccak256 } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const input = JSON.parse(readFileSync(process.argv[2]));
const file = process.argv[3];
assert.ok(file && process.env.JUICER_ACTOR_ARTIFACT);
const port = Number(process.env.JUICER_LOCAL_PORT || 8162);
assert.ok(Number.isInteger(port) && port > 0 && port < 65536);
const rpc = `http://127.0.0.1:${port}`;
assert.equal(input.rpc, rpc);
assert.equal(input.status, 'native-multi-user-multi-vault-campaign-passed');
const r = existsSync(file) ? JSON.parse(readFileSync(file)) : { rpc, fork: input.fork, calls: [], checks: {} };
assert.equal(r.rpc, rpc);
const save = () => writeFileSync(file, JSON.stringify(r, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
const key = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const account = privateKeyToAccount(key);
const chain = { id: input.fork.chainId, name: 'Local validation only', nativeCurrency: { name: 'WETH', symbol: 'WETH', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc, { timeout: 180000 }), pollingInterval: 1000, cacheTime: 0 });
const wallet = createWalletClient({ chain, account, transport: http(rpc, { timeout: 180000 }) });
const ws = new WsProvider(`ws://127.0.0.1:${port}`, 2500, {}, 180000);
const api = await ApiPromise.create({ provider: ws, noInitWarn: true });
const { vault, source, harvester, tbtcVault, buffer } = input.addresses;
const { hollar, prime, pool } = input.market;
const tokenAbi = parseAbi(['function approve(address,uint256) returns(bool)', 'function balanceOf(address) view returns(uint256)']);
const poolAbi = JSON.parse(readFileSync(new URL('../../deployments/hydration/Pool-Implementation.json', import.meta.url))).abi;
const actorArt = JSON.parse(readFileSync(process.env.JUICER_ACTOR_ARTIFACT));
const read = (address, abi, functionName, args = []) => pub.readContract({ address, abi, functionName, args });
const vr = (fn, args = []) => read(vault, artifact('CollateralVault').abi, fn, args);
// Chopsticks 2.3.0 uses Frontier's estimate=true mode and does not reject
// unsuccessful call estimates. Hydration builds fc-rpc with
// rpc-binary-search-estimate (estimate=false). Reproduce that bounded search
// locally; never change the runtime, gas cap, keeper budget or transactions.
async function nativeEstimate(request) {
  let high = request.gas ?? maxTransactionGas, low = 21_000n;
  const trials = [];
  await pub.simulateContract({ ...request, gas: high });
  trials.push({ gas: high, success: true });
  while (high - low > high / 10n) {
    const mid = (high + low) / 2n;
    try {
      await pub.simulateContract({ ...request, gas: mid });
      high = mid; trials.push({ gas: mid, success: true });
    } catch (e) {
      let cause = e;
      let executionFailure = false;
      while (cause) {
        executionFailure ||= cause.name === 'ExecutionRevertedError' || cause.code === 3;
        cause = cause.cause;
      }
      if (!executionFailure) throw e;
      low = mid; trials.push({ gas: mid, success: false });
    }
  }
  r.gasSearches ??= [];
  r.gasSearches.push({ address: request.address, functionName: request.functionName, args: request.args, trials, estimate: high }); save();
  return high;
}
async function send(label, address, abi, functionName, args = []) {
  if (r.calls.some(c => c.label === label)) return;
  const gasPrice = (await pub.getGasPrice()) * 2n;
  const estimate = await nativeEstimate({ account, address, abi, functionName, args, gas: maxTransactionGas, gasPrice });
  const gas = (estimate * 110n + 99n) / 100n;
  assert.ok(gas <= maxTransactionGas, `${label}: estimated gas ${estimate} exceeds native budget with margin`);
  let hash;
  for (let attempt = 0; ; ++attempt) {
    try { hash = await wallet.writeContract({ address, abi, functionName, args, gas, gasPrice: gasPrice + BigInt(attempt), type: 'legacy' }); break; }
    catch (e) { if (attempt >= 3 || !String(e).includes('Expected input with 32 bytes')) throw e; }
  }
  const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 240000 });
  r.calls.push({ label, hash, estimate, gas, gasUsed: receipt.gasUsed, status: receipt.status }); save();
  assert.equal(receipt.status, 'success', label);
  console.log(label, 'gas', receipt.gasUsed.toString());
}
async function advance(seconds) {
  const now = BigInt((await api.query.timestamp.now()).toString()) / 1000n;
  const next = now + seconds;
  await ws.send('dev_setStorage', [[[api.query.timestamp.now.key(), u8aToHex(api.registry.createType('u64', (next * 1000n).toString()).toU8a())]]]);
  await ws.send('dev_newBlock', [{ count: 1, relayChainStateOverrides: [[
    '0x1cb6f36e027abb2091cfb5110ab5087f06155b3cd9a8c9e5e9a23fd5dc13a5ed',
    u8aToHex(api.registry.createType('u64', (next / 6n + 1n).toString()).toU8a()),
  ]] }]);
  assert.ok(BigInt((await api.query.timestamp.now()).toString()) / 1000n >= next);
}
try {
  await ws.send('dev_setBlockBuildMode', ['Instant']);
  if (!r.actor) {
    const data = encodeDeployData({ abi: actorArt.abi, bytecode: actorArt.bytecode.object });
    const estimate = await pub.estimateGas({ account, data, gas: maxTransactionGas });
    const hash = await wallet.deployContract({ abi: actorArt.abi, bytecode: actorArt.bytecode.object, gas: estimate * 11n / 10n, gasPrice: (await pub.getGasPrice()) * 2n, type: 'legacy' });
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 240000 });
    assert.equal(receipt.status, 'success');
    r.actor = receipt.contractAddress;
    r.actorDeployment = { hash, gasUsed: receipt.gasUsed, codeHash: keccak256(await pub.getBytecode({ address: r.actor })) };
    save();
  }
  process.env.RPC_URL = rpc;
  process.env.LOOPER_PRIVATE_KEY = key;
  process.env.SUBLOOP_ADDRESS = source;
  process.env.VAULT_ADDRESSES = [vault, tbtcVault].join(',');
  process.env.HARVESTER_ADDRESS = harvester;
  process.env.POOL_ADDRESS = pool;
  process.env.GAS_ASSET_ADDRESS = input.market.collateral;
  process.env.JUICER_ROUNDING_RESERVES = JSON.stringify(input.roundingPolicies);
  const { JuicerLooper } = await import('../../juicer-vault/looper/dist/looper.js');
  const keeper = new JuicerLooper();
  keeper.publicClient.estimateContractGas = nativeEstimate;
  r.rpcCompatibility = 'Local eth_estimateGas uses bounded eth_call search, matching Hydration fc-rpc rpc-binary-search-estimate; original native runtime and transaction budgets retained';
  const originalWrite = keeper.walletClient.writeContract.bind(keeper.walletClient);
  keeper.walletClient.writeContract = async (request) => {
    let hash, attempt = 0;
    for (;;) {
      try { hash = await originalWrite({ ...request, gasPrice: request.gasPrice + BigInt(attempt) }); break; }
      catch (e) { if (attempt++ >= 3 || !String(e).includes('Expected input with 32 bytes')) throw e; }
    }
    r.keeperSubmissions ??= [];
    r.keeperSubmissions.push({ functionName: request.functionName, address: request.address, gas: request.gas,
      gasPrice: request.gasPrice + BigInt(attempt), localSignatureRetries: attempt, hash }); save();
    return hash;
  };
  const originalReceipt = keeper.publicClient.waitForTransactionReceipt.bind(keeper.publicClient);
  keeper.publicClient.waitForTransactionReceipt = async (request) => {
    const receipt = await originalReceipt(request);
    Object.assign(r.keeperSubmissions.find(s => s.hash === request.hash), {
      status: receipt.status, gasUsed: receipt.gasUsed, effectiveGasPrice: receipt.effectiveGasPrice,
    }); save();
    return receipt;
  };
  if (!r.checks.yieldOwnership) {
    // Explicit source-income fixture, separate from organic yield/APY evidence.
    await send('incomeApprove', prime, tokenAbi, 'approve', [pool, 1000n * 10n ** 6n]);
    await send('incomeFixture', pool, poolAbi, 'supply', [prime, 1000n * 10n ** 6n, source, 0]);
    await send('checkpoint', vault, artifact('CollateralVault').abi, 'sync');
    const module = await vr('yieldAccounting');
    const earned = owner => read(module, artifact('JuicerYieldAccounting').abi, 'earnedAssets', [owner]);
    if (!r.ownership) {
      const shares = await vr('balanceOf', [account.address]);
      r.ownership = { before: await earned(account.address), transferShares: shares / 2n, module };
      assert.ok(r.ownership.before > 0n && r.ownership.transferShares > 0n); save();
    }
    await send('transferAfterIncome', vault, artifact('CollateralVault').abi, 'transfer', [r.actor, BigInt(r.ownership.transferShares)]);
    assert.equal(await earned(r.actor), 0n, 'recipient captured yield earned before transfer');
    r.ownership.afterTransfer = await earned(account.address);
    assert.ok(r.ownership.afterTransfer >= BigInt(r.ownership.before) * 9999n / 10000n);
    const balanceBefore = await vr('balanceOf', [account.address]);
    assert.equal(await keeper.poke(artifact('Harvester').abi, harvester, 'harvest', 'native owned harvest', [[]]), true);
    r.ownership.recipientAfterHarvest = await earned(r.actor);
    assert.ok(r.ownership.recipientAfterHarvest <= BigInt(r.ownership.before) / 10000n + 1_000_000_000n,
      'recipient captured material earlier income');
    r.ownership.creditedShares = (await vr('balanceOf', [account.address])) - balanceBefore;
    assert.ok(r.ownership.creditedShares > 0n, 'the harvest did not credit the owner\'s balance');
    r.checks.yieldOwnership = true; save();
  }
  if (!r.checks.reinvestment) {
    // Finish the campaign's late source claims before measuring an upward
    // rebalance. The real scheduler must respect those repayment priorities.
    const sr = (fn, args = []) => read(source, artifact('SubLoop').abi, fn, args);
    for (let i = 0; i < 16; ++i) {
      const pending = await sr('unwindTargetEquity')
        + await sr('pendingUnwindOf', [vault]) + await sr('pendingUnwindOf', [tbtcVault]);
      if (pending === 0n) break;
      await keeper.runCycle();
    }
    assert.equal(await sr('unwindTargetEquity'), 0n, 'old source repayments are still pending');
    r.reinvestment = {
      debtBefore: await read(input.market.hollarDebt, tokenAbi, 'balanceOf', [vault]),
      sourceSharesBefore: await vr('loopShares'),
      creditBefore: await vr('reinvestAssets'),
    };
    assert.ok(r.reinvestment.creditBefore > 0n);
    keeper.cycle = 9; // Run the real periodic maintenance branch now.
    await keeper.runCycle();
    r.reinvestment.debtAfter = await read(input.market.hollarDebt, tokenAbi, 'balanceOf', [vault]);
    r.reinvestment.sourceSharesAfter = await vr('loopShares');
    assert.ok(r.reinvestment.debtAfter > r.reinvestment.debtBefore);
    assert.ok(r.reinvestment.sourceSharesAfter > r.reinvestment.sourceSharesBefore);
    r.checks.reinvestment = true; save();
  }
  if (!r.queue) {
    r.queue = { first: await vr('queueTail'), sharesPerRequest: (await vr('balanceOf', [r.actor])) / 32n };
    assert.ok(r.queue.sharesPerRequest > 0n); save();
  }
  for (let i = 0; i < 4; ++i) await send(`queue${i}`, r.actor, actorArt.abi, 'request', [vault, BigInt(r.queue.sharesPerRequest), 8n]);
  if (!r.queue.timeAdvanced) { await advance(43200n); r.queue.timeAdvanced = true; save(); }
  const end = BigInt(r.queue.first) + 32n;
  while (await vr('queueUnwind') < end) {
    const before = await vr('queueUnwind');
    await send(`start${before}`, vault, artifact('CollateralVault').abi, 'startUnwinds', [16n]);
    assert.ok(await vr('queueUnwind') > before, 'unwind start did not progress');
  }
  // Explicitly fund every cohort to isolate maximum settlement execution cost.
  await send('queueRecoveryApprove', hollar, tokenAbi, 'approve', [r.actor, 3200n * 10n ** 18n]);
  for (let i = 0; i < 2; ++i) await send(`queueRecovery${i}`, r.actor, actorArt.abi, 'fund',
    [hollar, buffer, BigInt(r.queue.first) + BigInt(i * 16) + 1n, 16n, 100n * 10n ** 18n]);
  if (!r.checks.nativeQueueWithinKeeperBudget) {
    r.queue.headBefore = await vr('queueHead'); save();
    const settled = await keeper.poke(artifact('CollateralVault').abi, vault, 'pokeSettle', 'native 32-request settlement');
    r.queue.headAfter = await vr('queueHead');
    r.checks.nativeQueueWithinKeeperBudget = settled && r.queue.headAfter === end;
    save();
    assert.equal(r.checks.nativeQueueWithinKeeperBudget, true, 'native queue cannot execute within keeper budget');
  }
  if (!r.checks.nativeEightRequestStart) {
    if (!r.extraQueue) { r.extraQueue = { first: await vr('queueTail') }; save(); }
    await send('extraShares', vault, artifact('CollateralVault').abi, 'transfer', [r.actor, BigInt(r.queue.sharesPerRequest) * 8n]);
    await send('extraRequests', r.actor, actorArt.abi, 'request', [vault, BigInt(r.queue.sharesPerRequest), 8n]);
    if (!r.extraQueue.timeAdvanced) { await advance(43200n); r.extraQueue.timeAdvanced = true; save(); }
    assert.equal(await keeper.poke(artifact('CollateralVault').abi, vault, 'startUnwinds', 'native eight-request start', [8n]), true);
    assert.equal(await vr('queueUnwind'), BigInt(r.extraQueue.first) + 8n);
    r.checks.nativeEightRequestStart = true; save();
  }
  if (!r.checks.nativeEightRequestSettlement) {
    await send('extraRecoveryApprove', hollar, tokenAbi, 'approve', [r.actor, 800n * 10n ** 18n]);
    await send('extraRecovery', r.actor, actorArt.abi, 'fund', [hollar, buffer, BigInt(r.extraQueue.first) + 1n, 8n, 100n * 10n ** 18n]);
    assert.equal(await keeper.poke(artifact('CollateralVault').abi, vault, 'pokeSettle', 'native eight-request settlement'), true);
    assert.equal(await vr('queueHead'), BigInt(r.extraQueue.first) + 8n);
    r.checks.nativeEightRequestSettlement = true;
  }
  r.status = 'passed';
  r.limitations = ['Source income is a donated 1000 PRIME fixture, not organic APY', '40 exit cohorts receive 100 HOLLAR each to isolate settlement cost', 'Cooldown uses local native time advancement', 'Local execution is not production activation'];
  if (r.error) { r.priorFailure = r.error; }
  delete r.error;
  save();
  console.log('NATIVE OWNERSHIP AND QUEUE PASS', file);
} catch (e) {
  r.error = e.shortMessage || String(e); save(); console.error(r.error); process.exitCode = 1;
} finally { await api.disconnect(); }
