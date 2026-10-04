// Local Hydration fork only. Run native-deploy.mjs and native-discount.mjs first.
// Records strict, unchanged-market quotes; never alters the oracle to force entry.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync} from 'node:fs';
import {artifact, artifactManifest, maxTransactionGas} from './native-artifacts.mjs';
const require = createRequire(new URL('../../package.json', import.meta.url));
const {ApiPromise, WsProvider} = require('@polkadot/api');
const {blake2AsHex} = require('@polkadot/util-crypto');
const {hexToU8a, u8aToHex, u8aConcat, compactToU8a} = require('@polkadot/util');
const {createPublicClient, createWalletClient, http, parseAbi, encodeFunctionData,
  encodeDeployData, keccak256, toHex, toFunctionSelector} = require('viem');
const {privateKeyToAccount} = require('viem/accounts');
const port = Number(process.env.PROPELLER_LOCAL_PORT);
assert.ok(Number.isInteger(port) && port > 0 && port <= 65535, 'explicit local port required');
assert.ok(process.argv[2], 'deployment result path required');
const file = process.argv[2], r = JSON.parse(readFileSync(file, 'utf8'));
const rpc = `http://127.0.0.1:${port}`;
assert.equal(r.rpc, rpc);
assert.equal(r.status, 'combined-stack-deployed-and-wired');
const account = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const ws = new WsProvider(`ws://127.0.0.1:${port}`, 2500, {}, 180000);
const api = await ApiPromise.create({provider: ws, noInitWarn: true});
const chain = {id: r.fork.chainId, name: 'Local Hydration fork',
  nativeCurrency: {name: 'WETH', symbol: 'WETH', decimals: 18}, rpcUrls: {default: {http: [rpc]}}};
const pub = createPublicClient({chain, transport: http(rpc, {timeout: 180000}), pollingInterval: 1000, cacheTime: 0});
const wallet = createWalletClient({account, chain, transport: http(rpc, {timeout: 180000})});
const {vault, source, harvester, fees, buffer, yieldAccounting} = r.addresses;
const {collateral, hollar, aPrime, hollarDebt} = r.market;
const token = parseAbi(['function approve(address,uint256) returns(bool)', 'function balanceOf(address) view returns(uint256)']);
const d = r.deferredDeposit ??= {checks: {}, calls: [], quotes: [], productionApproval: false};
const save = () => {
  d.artifacts = {...d.artifacts, ...artifactManifest};
  writeFileSync(file, JSON.stringify(r, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
};
const read = (name, address, functionName, args = []) => pub.readContract({address, abi: artifact(name).abi, functionName, args});
async function send(label, address, abi, functionName, args = []) {
  if (d.calls.some(c => c.label === label)) return;
  const gasPrice = await pub.getGasPrice() * 2n;
  const options = {account, address, abi, functionName, args, gasPrice, type: 'legacy'};
  // This viem version omits `gas` from estimateContractGas's RPC payload. The
  // local fork then estimates with its 25M default, above the native tx cap.
  // Pass the ceiling explicitly and reserve the same 20% submission margin.
  const estimateCeiling = maxTransactionGas * 100n / 120n;
  const estimate = BigInt(await pub.request({method: 'eth_estimateGas', params: [{
    from: account.address, to: address, data: encodeFunctionData({abi, functionName, args}),
    gas: toHex(estimateCeiling), gasPrice: toHex(gasPrice),
  }, 'latest']}));
  const gas = (estimate * 120n + 99n) / 100n;
  console.log(label, 'gas estimate', estimate.toString(), 'with margin', gas.toString());
  assert.ok(gas <= maxTransactionGas, `${label}: ${estimate} estimate plus 20% exceeds native gas cap`);
  // Chopsticks can return used gas for a reverted estimate. Require successful
  // execution at the actual submission allowance before sending anything.
  await pub.simulateContract({...options, gas});
  let hash;
  for (let attempt = 0; ; ++attempt) {
    try { hash = await wallet.writeContract({...options, gas, gasPrice: gasPrice + BigInt(attempt)}); break; }
    catch (error) { if (attempt >= 3 || !String(error).includes('Expected input with 32 bytes')) throw error; }
  }
  const receipt = await pub.waitForTransactionReceipt({hash, timeout: 240000});
  assert.equal(receipt.status, 'success', label);
  d.calls.push({label, hash, block: receipt.blockNumber, estimateCeiling,
    estimatedGas: estimate, submittedGas: gas, gasUsed: receipt.gasUsed});
  save();
  console.log(label, receipt.gasUsed.toString());
}
const call = (label, name, address, fn, args = []) => send(label, address, artifact(name).abi, fn, args);
async function whitelist() {
  const calls = [];
  for (const address of [vault, source, harvester, fees, buffer, yieldAccounting]) {
    const who = await api.call.evmAccountsApi.accountId(address);
    if (!(await api.call.dusterApi.isWhitelisted(who)).isTrue) calls.push(api.tx.duster.whitelistAccount(who));
  }
  if (!calls.length) return;
  const call = api.tx.utility.batchAll(calls), body = hexToU8a(call.method.toHex());
  const hash = blake2AsHex(body), len = body.length;
  await ws.send('dev_setStorage', [[[api.query.preimage.preimageFor.key([hash, len]), u8aToHex(u8aConcat(compactToU8a(len), body))]]]);
  await ws.send('dev_setStorage', [{Preimage: {RequestStatusFor: [[[hash], {Requested: {maybeTicket: null, count: 1, maybeLen: len}}]]}}]);
  const target = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
  await ws.send('dev_setStorage', [{Scheduler: {Agenda: [[[target], [{maybeId: null, priority: 0,
    call: {Lookup: {hash_: hash, len}}, maybePeriodic: null, origin: {system: 'Root'}}]]]}}]);
  await ws.send('dev_newBlock', [{count: 1}]);
  const event = (await api.query.system.events()).find(({event}) => event.section === 'scheduler' && event.method === 'Dispatched');
  assert.deepEqual(event?.event.data.toJSON()[2], {ok: null});
}
try {
  await ws.send('dev_setBlockBuildMode', ['Instant']); // proves the endpoint is a local dev fork
  await whitelist();
  if (!d.funded) {
    const who = (await api.call.evmAccountsApi.accountId(account.address)).toString();
    const value = api.registry.createType('OrmlTokensAccountData', {free: (10n * 10n ** 18n).toString(), reserved: 0, frozen: 0});
    await ws.send('dev_setStorage', [[[api.query.tokens.accounts.key(who, 34), u8aToHex(value.toU8a())]]]);
    d.funded = true;
    d.overrides = ['Local public development account collateral', 'Fork governance custody dust whitelist'];
    save();
  }
  assert.equal(await read('CollateralVault', vault, 'deferredDeployment'), true);
  if (!d.controller) {
    const art = artifact('ExecutionController');
    const data = encodeDeployData({abi: art.abi, bytecode: art.bytecode.object, args: [account.address, 60n, 5n]});
    const gasPrice = await pub.getGasPrice() * 2n;
    const estimate = await pub.estimateGas({account, data, gas: maxTransactionGas, gasPrice});
    const gas = (estimate * 110n + 99n) / 100n;
    assert.ok(gas <= maxTransactionGas);
    const hash = await wallet.sendTransaction({data, gas, gasPrice, type: 'legacy'});
    const receipt = await pub.waitForTransactionReceipt({hash, timeout: 240000});
    assert.equal(receipt.status, 'success');
    d.controller = receipt.contractAddress;
    d.deployment = {hash, gasUsed: receipt.gasUsed, estimatedGas: estimate,
      codeHash: keccak256(await pub.getBytecode({address: d.controller}))};
    save();
  }
  const c = d.controller, group = keccak256(toHex('native-deferred-entry'));
  const expiry = (await pub.getBlock()).timestamp + 30n * 86400n;
  await call('entry-budget', 'ExecutionController', c, 'configureBudget', [group, hollar, 100n * 10n ** 18n, 10n ** 18n, expiry]);
  await call('entry-limit', 'ExecutionController', c, 'configureLimit', [source, hollar, aPrime, group, 10n ** 18n, 50n * 10n ** 18n]);
  await call('entry-pacing', 'ExecutionController', c, 'configurePacing', [group, 60n]);
  const lane = await read('ExecutionController', c, 'lane', [source, hollar, aPrime]);
  assert.equal(await read('ExecutionController', c, 'maxShortfallBps', [lane]), 0);
  await call('rebalance-action', 'ExecutionController', c, 'configureAction', [vault, toFunctionSelector('rebalance()'), true]);
  for (const [name, address] of [['CollateralVault', vault], ['SubLoop', source], ['Harvester', harvester]])
    await call(`bind-${name}`, name, address, 'setExecutionController', [c]);
  const ed = BigInt((await api.query.assetRegistry.assets(34)).unwrap().existentialDeposit.toString());
  const reserve = ed * 4n + 1000000000n;
  await send('reserve-approve', collateral, token, 'approve', [vault, reserve]);
  await call('reserve-fund', 'CollateralVault', vault, 'fundRoundingReserve', [reserve]);
  await send('deposit-approve', collateral, token, 'approve', [vault, 2n * 10n ** 18n]);
  await call('direct-deposit', 'CollateralVault', vault, 'deposit', [2n * 10n ** 18n, account.address]);
  const debt = () => pub.readContract({address: hollarDebt, abi: token, functionName: 'balanceOf', args: [vault]});
  assert.equal(await debt(), 0n);
  assert.equal(await read('CollateralVault', vault, 'loopShares'), 0n);
  assert.equal(await read('CollateralVault', vault, 'reinvestAssets'), 2n * 10n ** 18n);
  d.checks.largeDepositWaitsDebtFree = true;
  // Zero delay is explicitly a local fixture. It does not alter a production delay.
  await call('local-zero-delay', 'CollateralVault', vault, 'setWithdrawalDelay', [0]);
  const shares = (await read('CollateralVault', vault, 'balanceOf', [account.address])) / 2n;
  await call('pre-deploy-request', 'CollateralVault', vault, 'requestRedeem', [shares, account.address]);
  await call('pre-deploy-start', 'CollateralVault', vault, 'startUnwinds', [1n]);
  await call('pre-deploy-settle', 'CollateralVault', vault, 'pokeSettle');
  const request = await read('CollateralVault', vault, 'redemptions', [0n]);
  const before = await pub.readContract({address: collateral, abi: token, functionName: 'balanceOf', args: [account.address]});
  await call('pre-deploy-claim', 'CollateralVault', vault, 'claim', [0n, account.address]);
  const after = await pub.readContract({address: collateral, abi: token, functionName: 'balanceOf', args: [account.address]});
  assert.equal(after - before, request[2]);
  assert.equal(await debt(), 0n);
  assert.equal(await read('CollateralVault', vault, 'loopShares'), 0n);
  d.checks.withdrawalBeforeDeployment = true;
  save();
  const block = await pub.getBlock();
  const data = encodeFunctionData({abi: artifact('CollateralVault').abi, functionName: 'rebalance'});
  for (const amount of [50n, 25n, 10n, 5n, 1n]) {
    try {
      const {result: [work, fills]} = await pub.simulateContract({account, address: c, abi: artifact('ExecutionController').abi,
        functionName: 'previewBounded', args: [vault, data, [{lane, amountIn: amount * 10n ** 18n, minOut: 0n}]],
        blockNumber: block.number, gas: maxTransactionGas});
      d.quotes.push({block: block.number, amountHollar: amount, work, fills, acceptable: fills.length > 0});
    } catch (error) {
      assert.match(String(error), /revert/i, 'RPC failures are not negative price evidence');
      d.quotes.push({block: block.number, amountHollar: amount, acceptable: false,
        revert: error.shortMessage ?? String(error)});
    }
    save();
  }
  assert.equal(await debt(), 0n, 'even native previews must roll back borrowed debt');
  assert.equal(await read('CollateralVault', vault, 'loopShares'), 0n);
  d.checks.previewsRollback = true;
  d.strictOracleQuotesAvailable = d.quotes.some(q => q.acceptable);
  d.status = 'deferred-deposit-and-pre-deployment-withdrawal-passed';
  d.scope = 'Local native execution with listed synthetic and funded rounding fixture; no oracle override, no mainnet activation, no executed strategy swap or APY claim.';
  delete d.error;
  save();
  console.log(d.status, 'strict oracle quotes available:', d.strictOracleQuotesAvailable);
} catch (error) {
  d.error = error.stack ?? String(error);
  save();
  console.error(error);
  process.exitCode = 1;
} finally { await api.disconnect(); }
