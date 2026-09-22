import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import assert from 'node:assert/strict';

const require = createRequire(new URL('../../package.json', import.meta.url));
const { ApiPromise, WsProvider } = require('@polkadot/api');
const { hexToU8a, u8aToHex } = require('@polkadot/util');
const { createPublicClient, createWalletClient, http, encodeFunctionData, keccak256 } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const { ethers } = require('ethers');

// Fixed local endpoint and public development key. Never reads a production key.
const PORT = Number(process.env.PROPELLER_LOCAL_PORT || 8142);
assert.ok(Number.isInteger(PORT) && PORT > 0 && PORT <= 65535);
const RPC = `http://127.0.0.1:${PORT}`;
const WS = `ws://127.0.0.1:${PORT}`;
const OUT = new URL('../../propeller-vault/out', import.meta.url).pathname;
const RESULT = process.argv[2] || '/tmp/propeller-buffer-native-result.json';
const account = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const treasury = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const committee = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC';
const POOL = '0x1b02E051683b5cfaC5929C25E84adb26ECf87B38';
const HOLLAR = '0x531a654d1696ED52e7275A8cede955E82620f99a';
const ETH = '0x0000000000000000000000000000000100000022';
const PRIME = '0x000000000000000000000000000000010000002B';
const result = existsSync(RESULT) ? JSON.parse(readFileSync(RESULT, 'utf8')) : { baseCommit: '55acd38229f2ccc949f00c474e641d6a0df551b2', branch: 'feat/propeller-interest-buffer', uncommitted: true, rpc: RPC, deployments: [], calls: [], checks: {} };
const save = () => writeFileSync(RESULT, JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
assert.equal(result.rpc, RPC, 'result belongs to another local fork');
const artifact = name => JSON.parse(readFileSync(`${OUT}/${name}.sol/${name}.json`, 'utf8'));
const bytecode = object => object.startsWith('0x') ? object : `0x${object}`;

const provider = new WsProvider(WS, 2500, {}, 120_000);
const api = await ApiPromise.create({ provider, noInitWarn: true });
try {
  // Prove this is the local dev fork before making any state changes.
  await provider.send('dev_setBlockBuildMode', ['Instant']);
  const chainId = Number(await provider.send('eth_chainId', []));
  const head = await api.rpc.chain.getHeader();
  result.fork ??= { chainId, block: head.number.toString(), hash: head.hash.toHex(), runtime: (await api.rpc.state.getRuntimeVersion()).toJSON() };
  result.upstream = 'wss://hdx.tarn.hydration.cloud';
  console.log('FORK', JSON.stringify(result.fork));
  const chain = { id: chainId, name: 'Hydration local Chopsticks', nativeCurrency: { name: 'WETH', symbol: 'WETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } };
  const pub = createPublicClient({ chain, transport: http(RPC, { timeout: 120_000 }), pollingInterval: 1000, cacheTime: 0 });
  const wallet = createWalletClient({ account, chain, transport: http(RPC, { timeout: 120_000 }) });
  const gasPrice = (await pub.getGasPrice()) * 2n;
  result.gasPrice = gasPrice;

  const extension = await api.query.evmAccounts.accountExtension(account.address);
  const mapped = new Uint8Array(32);
  if (extension.isSome) { mapped.set(hexToU8a(account.address)); mapped.set(extension.unwrap().toU8a(), 20); }
  else { mapped.set([0x45, 0x54, 0x48, 0]); mapped.set(hexToU8a(account.address), 4); }
  const ss58 = api.registry.createType('AccountId', mapped).toString();
  const tokenData = api.registry.createType('OrmlTokensAccountData', { free: (1000n * 10n ** 18n).toString(), reserved: '0', frozen: '0' });
  const systemData = api.registry.createType('AccountInfo', { nonce: 0, consumers: 0, providers: 1, sufficients: 1, data: { free: '1000000000000000000', reserved: '0', frozen: '0', flags: '0' } });
  if (result.deployments.length === 0) await provider.send('dev_setStorage', [[
    [api.query.tokens.accounts.key(ss58, 20), u8aToHex(tokenData.toU8a())],
    [api.query.system.account.key(ss58), u8aToHex(systemData.toU8a())],
    [api.query.evmAccounts.contractDeployer.key(account.address), '0x'],
  ]]);
  result.overrides = ['Parachain relay-parent override for local block production', 'Fund public development deployer with local HDX/WETH', 'Whitelist development deployer; no runtime/code-size/gas-limit overrides'];
  console.log('DEPLOYER', account.address, 'balance', (await pub.getBalance({ address: account.address })).toString(), 'gasPrice', gasPrice.toString());

  async function receipt(hash, label) {
    const r = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    console.log(label, r.status, 'gas', r.gasUsed.toString(), 'tx', hash);
    assert.equal(r.status, 'success', `${label} reverted`);
    return r;
  }
  async function deploy(name, args = [], label = name) {
    const art = artifact(name);
    const previous = result.deployments.find(d => d.label === label);
    if (previous) {
      assert.equal(keccak256(await pub.getBytecode({ address: previous.address })), previous.codeHash);
      console.log('VERIFIED PREVIOUS', label, previous.address);
      return previous.address;
    }
    console.log('DEPLOY', label, 'runtime bytes', (art.deployedBytecode.object.replace(/^0x/, '').length / 2));
    let hash;
    for (let attempt = 0; ; attempt++) {
      try {
        hash = await wallet.deployContract({ abi: art.abi, bytecode: bytecode(art.bytecode.object), args, gas: 12_000_000n, gasPrice: gasPrice + BigInt(attempt), type: 'legacy', nonce: await pub.getTransactionCount({ address: account.address }) });
        break;
      } catch (error) {
        if (attempt >= 3 || !String(error).includes('Expected input with 32 bytes')) throw error;
      }
    }
    const r = await receipt(hash, label);
    const code = await pub.getBytecode({ address: r.contractAddress });
    assert.ok(code && code !== '0x', `${label} has no code`);
    const runtimeBytes = (code.length - 2) / 2;
    assert.ok(runtimeBytes <= 24576);
    // Constructor-patched immutable slots are verified separately.
    const exactCodeMatch = code.toLowerCase() === bytecode(art.deployedBytecode.object).toLowerCase();
    result.deployments.push({ label, address: r.contractAddress, transactionHash: hash, block: r.blockNumber, gasUsed: r.gasUsed, runtimeBytes, codeHash: keccak256(code), exactCodeMatch, compiler: art.metadata?.compiler, settings: art.metadata?.settings });
    save();
    console.log('CREATED', label, r.contractAddress, runtimeBytes, 'bytes');
    return r.contractAddress;
  }
  async function call(name, address, functionName, args = []) {
    if (result.calls.some(c => c.label === `${name}.${functionName}` && c.address === address)) return;
    let hash;
    for (let attempt = 0; ; attempt++) {
      try {
        hash = await wallet.writeContract({ address, abi: artifact(name).abi, functionName, args, gas: 4_000_000n, gasPrice: gasPrice + BigInt(attempt), type: 'legacy' });
        break;
      } catch (error) {
        // Local decoder rejects valid leading-zero signatures before submission.
        if (attempt >= 3 || !String(error).includes('Expected input with 32 bytes')) throw error;
      }
    }
    const r = await receipt(hash, `${name}.${functionName}`);
    result.calls.push({ label: `${name}.${functionName}`, address, transactionHash: hash, gasUsed: r.gasUsed });
    save();
  }
  async function read(name, address, functionName, args = []) {
    return pub.readContract({ address, abi: artifact(name).abi, functionName, args });
  }

  const vaultImpl = await deploy('CollateralVault');
  const helper = await read('CollateralVault', vaultImpl, 'compoundLogic');
  const helperCode = await pub.getBytecode({address: helper});
  assert.equal(helperCode.toLowerCase(), bytecode(artifact('CompoundLogic').deployedBytecode.object).toLowerCase());
  result.checks.immutableHelper = {address: helper, runtimeBytes: (helperCode.length - 2) / 2, codeHash: keccak256(helperCode)};
  const synth = await deploy('SyntheticToken', ['Propeller Synthetic HOLLAR', 'psHOLLAR', account.address]);
  const subImpl = await deploy('SubLoop');
  const reserveAbi = JSON.parse(readFileSync(new URL('../../deployments/hydration/Pool-Implementation.json', import.meta.url), 'utf8')).abi;
  const ethReserve = await pub.readContract({ address: POOL, abi: reserveAbi, functionName: 'getReserveData', args: [ETH] });
  const primeReserve = await pub.readContract({ address: POOL, abi: reserveAbi, functionName: 'getReserveData', args: [PRIME] });
  const hollarReserve = await pub.readContract({ address: POOL, abi: reserveAbi, functionName: 'getReserveData', args: [HOLLAR] });
  result.market = { pool: POOL, hollar: HOLLAR, collateral: ETH, prime: PRIME, aEth: ethReserve.aTokenAddress, aPrime: primeReserve.aTokenAddress, hollarDebt: hollarReserve.variableDebtTokenAddress };
  console.log('MARKET', result.market);
  const subInit = encodeFunctionData({ abi: artifact('SubLoop').abi, functionName: 'initialize', args: [POOL, HOLLAR, PRIME, primeReserve.aTokenAddress, 1050000000000000000n, 1100000000000000000n, account.address] });
  const source = await deploy('ERC1967Proxy', [subImpl, subInit], 'SubLoop.proxy');
  const vaultInit = encodeFunctionData({ abi: artifact('CollateralVault').abi, functionName: 'initialize', args: ['Propeller ETH', 'pETH', ETH, POOL, source, account.address, HOLLAR, synth, ethReserve.aTokenAddress, hollarReserve.variableDebtTokenAddress, 1000000n * 10n ** 18n, account.address] });
  const vault = await deploy('ERC1967Proxy', [vaultImpl, vaultInit], 'CollateralVault.proxy');
  const buffer = await deploy('PropellerOperatingBuffer', [vault]);
  await call('CollateralVault', vault, 'setOperatingBuffer', [buffer]);
  await call('PropellerOperatingBuffer', buffer, 'configure', [7 * 86400, 10, 50000000000000000000000000n]);
  const harvester = await deploy('Harvester', [source, PRIME, account.address]);
  const fees = await deploy('PropellerFeeController', [account.address, treasury]);
  await call('SyntheticToken', synth, 'grantRole', [ethers.utils.id('MINTER_ROLE'), vault]);
  await call('SubLoop', source, 'registerVault', [vault]);
  await call('SubLoop', source, 'setHarvester', [harvester]);
  await call('Harvester', harvester, 'addVault', [vault]);
  await call('Harvester', harvester, 'setFeeController', [fees]);
  await call('CollateralVault', vault, 'setFeeController', [fees]);
  await call('PropellerFeeController', fees, 'registerVault', [vault, harvester]);
  assert.equal(await read('PropellerFeeController', fees, 'protocolFeeBps', [vault]), 500);
  await read('PropellerFeeController', fees, 'validateVault', [vault, harvester]);
  assert.equal((await read('CollateralVault', vault, 'asset')).toLowerCase(), ETH.toLowerCase());
  result.checks.feeBinding = true;
  result.checks.initialFeeBps = 500;
  result.addresses = { vaultImpl, synth, subImpl, source, vault, harvester, fees, buffer };
  result.status = 'core-stack-deployed-and-fees-wired';
  delete result.error;
  save();
  console.log('CORE STACK PASS; result', RESULT);
} catch (error) {
  result.status = 'failed';
  result.error = error.stack ?? String(error);
  save();
  console.error(error);
  process.exitCode = 1;
} finally {
  await api.disconnect();
}
