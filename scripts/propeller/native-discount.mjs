import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const require = createRequire(new URL('../../package.json', import.meta.url));
const { ApiPromise, WsProvider } = require('@polkadot/api');
const { blake2AsHex } = require('@polkadot/util-crypto');
const { compactToU8a, hexToU8a, u8aToHex, u8aConcat } = require('@polkadot/util');
const { ethers } = require('ethers');
const { createPublicClient, createWalletClient, http, keccak256 } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');

const PORT = Number(process.env.PROPELLER_LOCAL_PORT || 8142);
assert.ok(Number.isInteger(PORT) && PORT > 0 && PORT <= 65535);
const RPC = `http://127.0.0.1:${PORT}`;
const FILE = process.argv[2] || '/tmp/propeller-buffer-native-result.json';
const result = JSON.parse(readFileSync(FILE, 'utf8'));
assert.equal(result.rpc, RPC, 'result belongs to another local fork');
assert.equal(result.status, 'core-stack-deployed-and-fees-wired');
const account = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const COMMITTEE = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
const GOV = '0xAa7e0000000000000000000000000000000Aa7e0';
const { pool, collateral, aEth, hollarDebt } = result.market;
const { vault, synth } = result.addresses;
const artifact = name => JSON.parse(readFileSync(new URL(`../../propeller-vault/out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));
const save = () => writeFileSync(FILE, JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
const ws = new WsProvider(`ws://127.0.0.1:${PORT}`, 2500, {}, 180_000);
const api = await ApiPromise.create({ provider: ws, noInitWarn: true });
const chain = { id: result.fork.chainId, name: 'Local Chopsticks', nativeCurrency: { name: 'WETH', symbol: 'WETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 180_000 }), pollingInterval: 1000, cacheTime: 0 });
const wallet = createWalletClient({ account, chain, transport: http(RPC, { timeout: 180_000 }) });
const evm = new ethers.providers.JsonRpcProvider(RPC);
const iface = abi => new ethers.utils.Interface(abi);
const read = async (address, signature, args = []) => {
  const i = iface([signature]);
  const f = Object.keys(i.functions)[0];
  const value = await evm.call({ to: address, data: i.encodeFunctionData(f, args) });
  return i.decodeFunctionResult(f, value)[0];
};
try {
  await ws.send('dev_setBlockBuildMode', ['Manual']);
  const gasPrice = (await pub.getGasPrice()) * 2n;
  const provider = await read(pool, 'function ADDRESSES_PROVIDER() view returns (address)');
  const configurator = await read(provider, 'function getPoolConfigurator() view returns (address)');
  const acl = await read(provider, 'function getACLManager() view returns (address)');
  assert.equal(await read(acl, 'function isPoolAdmin(address) view returns (bool)', [GOV]), true);
  const poolAbi = JSON.parse(readFileSync(new URL('../../deployments/hydration/Pool-Implementation.json', import.meta.url), 'utf8')).abi;
  const reserve = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'getReserveData', args: [collateral] });
  const SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
  // This Chopsticks build encodes storage_at's U256 index as H256 (wrong byte
  // order). Read the native storage map instead of trusting eth_getStorageAt.
  const implementation = async address => {
    const slot = (await api.query.evm.accountStorages(address, SLOT)).toHex();
    const impl = `0x${slot.slice(-40)}`;
    assert.notEqual(impl, ethers.constants.AddressZero);
    assert.ok((await pub.getBytecode({ address: impl }))?.length > 2);
    return impl;
  };
  const treasury = await read(aEth, 'function RESERVE_TREASURY_ADDRESS() view returns (address)');
  const incentives = await read(aEth, 'function getIncentivesController() view returns (address)');

  // Scheduler injection simulates governance approval only on the isolated fork.
  // Actual configurator and debt-token authorization and EVM execution are retained.
  async function governanceCall(to, data, label, gas = 10_000_000) {
    if (result.calls.some(c => c.label === label)) return;
    console.log('SIMULATE', label);
    await pub.call({ account: GOV, to, data, gas: BigInt(gas) });
    const inner = api.tx.dispatcher.dispatchAsAaveManager(api.tx.evm.call(GOV, to, data, '0', String(gas), gasPrice.toString(), null, null, [], []));
    const callHex = inner.method.toHex();
    const hash = blake2AsHex(callHex);
    const body = hexToU8a(callHex);
    const len = body.length;
    await ws.send('dev_setStorage', [[[api.query.preimage.preimageFor.key([hash, len]), u8aToHex(u8aConcat(compactToU8a(len), body))]]]);
    const status = api.query.preimage.requestStatusFor ? 'RequestStatusFor' : 'StatusFor';
    await ws.send('dev_setStorage', [{ Preimage: { [status]: [[[hash], { Requested: { maybeTicket: null, count: 1, maybeLen: len } }]] } }]);
    const target = (await api.rpc.chain.getHeader()).number.toNumber() + 1;
    await ws.send('dev_setStorage', [{ Scheduler: { Agenda: [[[target], [{ maybeId: null, priority: 0, call: { Lookup: { hash_: hash, len } }, maybePeriodic: null, origin: { system: 'Root' } }]]] } }]);
    await ws.send('dev_newBlock', [{ count: 1 }]);
    const events = await (await api.at(await api.rpc.chain.getBlockHash(target))).query.system.events();
    const relevant = events.map(({ event }) => ({ section: event.section, method: event.method, data: event.data.toJSON() })).filter(e => ['evm', 'scheduler', 'dispatcher'].includes(e.section));
    console.log(label, JSON.stringify(relevant));
    assert.ok(relevant.some(e => e.section === 'evm' && e.method === 'Executed'), `${label}: missing success event`);
    assert.ok(!relevant.some(e => /Failed|CallUnavailable|PermanentlyOverweight/.test(e.method)), `${label}: failure event`);
    result.calls.push({ label, block: target, events: relevant, simulatedGovernance: true });
    save();
  }
  const configInterface = iface(['function initReserves(tuple(address aTokenImpl,address stableDebtTokenImpl,address variableDebtTokenImpl,uint8 underlyingAssetDecimals,address interestRateStrategyAddress,address underlyingAsset,address treasury,address incentivesController,string aTokenName,string aTokenSymbol,string variableDebtTokenName,string variableDebtTokenSymbol,string stableDebtTokenName,string stableDebtTokenSymbol,bytes params)[])']);
  const input = {
    aTokenImpl: await implementation(aEth),
    stableDebtTokenImpl: await implementation(reserve.stableDebtTokenAddress),
    variableDebtTokenImpl: await implementation(reserve.variableDebtTokenAddress),
    underlyingAssetDecimals: 18,
    interestRateStrategyAddress: reserve.interestRateStrategyAddress,
    underlyingAsset: synth, treasury, incentivesController: incentives,
    aTokenName: 'Propeller Synthetic aToken', aTokenSymbol: 'aPSYNTH',
    variableDebtTokenName: 'Propeller Synthetic Variable Debt', variableDebtTokenSymbol: 'vdPSYNTH',
    stableDebtTokenName: 'Propeller Synthetic Stable Debt', stableDebtTokenSymbol: 'sdPSYNTH', params: '0x',
  };
  console.log('RESERVE INPUT', JSON.stringify(input));
  await governanceCall(configurator, configInterface.encodeFunctionData('initReserves', [[input]]), 'Aave.initReserves(psHOLLAR)');
  const synthReserve = await pub.readContract({ address: pool, abi: poolAbi, functionName: 'getReserveData', args: [synth] });
  assert.notEqual(synthReserve.aTokenAddress, ethers.constants.AddressZero);
  result.addresses.aSynthetic = synthReserve.aTokenAddress;
  result.overrides.push('Scheduler/preimage injection to simulate governance execution of synthetic reserve listing and HOLLAR discount installation');
  await ws.send('dev_setBlockBuildMode', ['Instant']);
  const art = artifact('PropellerDiscount');
  let discount = result.addresses.discount;
  if (!discount) {
    const hash = await wallet.deployContract({ abi: art.abi, bytecode: art.bytecode.object, args: [hollarDebt, synth, synthReserve.aTokenAddress, account.address, COMMITTEE], gas: 6_000_000n, gasPrice, type: 'legacy' });
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: 240_000 });
    assert.equal(receipt.status, 'success');
    discount = receipt.contractAddress;
    const code = await pub.getBytecode({ address: discount });
    assert.ok(code && code !== '0x');
    result.deployments.push({ label: 'PropellerDiscount', address: discount, transactionHash: hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed, runtimeBytes: (code.length - 2) / 2, codeHash: keccak256(code) });
    result.addresses.discount = discount;
    save();
    console.log('PropellerDiscount DEPLOYED', discount, 'gas', receipt.gasUsed.toString());
  }
  await ws.send('dev_setBlockBuildMode', ['Manual']);
  const debt = iface(['function updateDiscountToken(address)', 'function updateDiscountRateStrategy(address)']);
  await governanceCall(hollarDebt, debt.encodeFunctionData('updateDiscountToken', [discount]), 'HOLLAR.updateDiscountToken', 2_000_000);
  await governanceCall(hollarDebt, debt.encodeFunctionData('updateDiscountRateStrategy', [discount]), 'HOLLAR.updateDiscountRateStrategy', 2_000_000);
  await ws.send('dev_setBlockBuildMode', ['Instant']);
  async function write(name, address, functionName, args) {
    const encodedArgs = JSON.stringify(args, (_, v) => typeof v === 'bigint' ? v.toString() : v);
    if (result.calls.some(c => c.label === `${name}.${functionName}` && c.address === address
      && (functionName !== 'setDiscountBps' || c.encodedArgs === encodedArgs))) return;
    let hash;
    for (let attempt = 0; ; ++attempt) {
      try {
        hash = await wallet.writeContract({ address, abi: artifact(name).abi, functionName, args,
          gas: 3_000_000n, gasPrice: gasPrice + BigInt(attempt), type: 'legacy' });
        break;
      } catch (error) {
        if (attempt >= 3 || !String(error).includes('Expected input with 32 bytes')) throw error;
      }
    }
    const r = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    assert.equal(r.status, 'success', functionName);
    result.calls.push({ label: `${name}.${functionName}`, address, encodedArgs, transactionHash: hash, gasUsed: r.gasUsed });
    save();
    console.log(functionName, 'success', r.gasUsed.toString());
  }
  await write('CollateralVault', vault, 'setDiscountController', [discount]);
  await write('PropellerDiscount', discount, 'registerVault', [vault]);
  await write('PropellerDiscount', discount, 'setDiscountBps', [8000]);
  assert.equal(await read(discount, 'function discountBps() view returns (uint16)'), 8000);
  await write('PropellerDiscount', discount, 'setDiscountBps', [0]);
  // Fork-only risk/oracle configuration needed for a real deposit rehearsal.
  await ws.send('dev_setBlockBuildMode', ['Manual']);
  const risk = iface(['function configureReserveAsCollateral(address,uint256,uint256,uint256)']);
  await governanceCall(configurator, risk.encodeFunctionData('configureReserveAsCollateral', [synth, 100, 9800, 10100]), 'Aave.configureSyntheticCollateral');
  const oracleAddress = await read(provider, 'function getPriceOracle() view returns (address)');
  const oracle = iface(['function setAssetSources(address[],address[])']);
  await governanceCall(oracleAddress, oracle.encodeFunctionData('setAssetSources', [[synth], ['0x6096C9D71F7c06024578a62F4B608a1Bb06834F8']]), 'Aave.configureSyntheticOracle');
  await ws.send('dev_setBlockBuildMode', ['Instant']);
  await write('SubLoop', result.addresses.source, 'configureDca', [222, 43, 1043, 143, 10000]);
  await write('SubLoop', result.addresses.source, 'setTranches', [100n * 10n ** 18n, 100n * 10n ** 6n]);
  result.testOnlyPolicy = { slippagePpm: 10000, trancheHollar: '100', productionApproval: false };
  assert.equal(await read(discount, 'function isRegistered(address) view returns (bool)', [vault]), true);
  assert.equal(await read(discount, 'function hasRole(bytes32,address) view returns (bool)', [ethers.utils.id('RATE_ADMIN_ROLE'), COMMITTEE]), true);
  result.checks.discountInstalledAndRegistered = true;
  result.checks.discountRateUpdateAndReset = true;
  result.checks.committeeRateRole = true;
  result.status = 'combined-stack-deployed-and-wired';
  delete result.discountError;
  result.infrastructureCaveat = 'Chopsticks eth_getStorageAt uses H256 encoding for runtime U256 slot index; implementation slots read from native EVM.AccountStorages instead.';
  save();
  console.log('COMBINED DEPLOYMENT PASS', FILE);
} catch (error) {
  result.discountError = error.stack ?? String(error);
  save();
  console.error(error);
  process.exitCode = 1;
} finally { await api.disconnect(); evm.removeAllListeners(); }
