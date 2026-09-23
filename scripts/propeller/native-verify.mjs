import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const require = createRequire(new URL('../../package.json', import.meta.url));
const { createPublicClient, http, keccak256 } = require('viem');
const { ApiPromise, WsProvider } = require('@polkadot/api');
const FILE = process.argv[2] || '/tmp/propeller-buffer-native-result.json';
const PORT = Number(process.env.PROPELLER_LOCAL_PORT || 8142);
assert.ok(Number.isInteger(PORT) && PORT > 0 && PORT <= 65535);
const result = JSON.parse(readFileSync(FILE, 'utf8'));
assert.equal(result.rpc, `http://127.0.0.1:${PORT}`, 'result belongs to another local fork');
const lifecyclePassed = result.status === 'native-multi-user-multi-vault-campaign-passed';
assert.ok(lifecyclePassed || result.status === 'native-entry-blocked-by-strict-slippage');
const pub = createPublicClient({ transport: http(`http://127.0.0.1:${PORT}`, { timeout: 120_000 }), cacheTime: 0 });
const artifact = name => JSON.parse(readFileSync(name === 'HydraAugustus'
  ? process.env.PROPELLER_ADAPTER_ARTIFACT
  : new URL(`../../propeller-vault/out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));
const api = await ApiPromise.create({ provider: new WsProvider(`ws://127.0.0.1:${PORT}`), noInitWarn: true });

try {
for (const deployment of result.deployments) {
  const name = deployment.label.endsWith('.proxy') ? 'ERC1967Proxy'
    : deployment.label.startsWith('PropellerMainDebt') ? 'PropellerMainDebt' : deployment.label;
  const art = artifact(name);
  const code = await pub.getBytecode({ address: deployment.address });
  assert.equal(keccak256(code), deployment.codeHash);
  const deployed = Buffer.from(code.slice(2), 'hex');
  const expected = Buffer.from(art.deployedBytecode.object.replace(/^0x/, ''), 'hex');
  assert.equal(deployed.length, expected.length);
  // Only constructor-patched immutable slots may differ from the compiler template.
  for (const references of Object.values(art.deployedBytecode.immutableReferences ?? {})) {
    for (const { start, length } of references) {
      deployed.fill(0, start, start + length);
      expected.fill(0, start, start + length);
    }
  }
  assert.ok(deployed.equals(expected), `${deployment.label}: deployed bytecode differs from the PR artifact`);
  try {
    const receipt = await pub.getTransactionReceipt({ hash: deployment.transactionHash });
    assert.equal(receipt.status, 'success');
    deployment.receiptReverified = true;
  } catch (error) {
    // Chopsticks prunes old receipt lookup entries as the rehearsal advances.
    if (error.name !== 'TransactionReceiptNotFoundError') throw error;
    deployment.receiptReverified = false;
    deployment.historicalReceiptUnavailable = true;
  }
  deployment.artifactMatchExceptImmutables = true;
  console.log(deployment.label, deployment.runtimeBytes, 'bytes;', deployment.gasUsed, 'gas; verified');
}
const { vault, vaultImpl, source, subImpl, fees, harvester, discount } = result.addresses;
const sourceRead = functionName => pub.readContract({address: source, abi: artifact('SubLoop').abi, functionName});
result.verifiedPolicy = {
  slippagePpm: Number(await sourceRead('dcaSlippagePpm')),
  deployTrancheWei: (await sourceRead('deployTranche')).toString(),
  unwindTranchePrimeUnits: (await sourceRead('unwindTranche')).toString(),
};
if (!lifecyclePassed) assert.equal(result.verifiedPolicy.slippagePpm, 10000);
const helper = await pub.readContract({ address: vaultImpl, abi: artifact('CollateralVault').abi, functionName: 'compoundLogic' });
assert.equal((await pub.getBytecode({address: helper})).toLowerCase(), artifact('CompoundLogic').deployedBytecode.object.toLowerCase());
result.checks.constructorHelperMatchesArtifact = true;
const SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
for (const [proxy, implementation] of [[vault, vaultImpl], [source, subImpl], [result.addresses.tbtcVault, vaultImpl]]) {
  const slot = (await api.query.evm.accountStorages(proxy, SLOT)).toHex();
  assert.equal(`0x${slot.slice(-40)}`.toLowerCase(), implementation.toLowerCase());
}
result.finalBufferExits = [];
for (const checkedVault of [vault, result.addresses.tbtcVault]) {
const buffer = await pub.readContract({ address: checkedVault, abi: artifact('CollateralVault').abi, functionName: 'mainDebt' });
const bufferRead = functionName => pub.readContract({address: buffer, abi: artifact('PropellerMainDebt').abi, functionName});
assert.equal((await bufferRead('vault')).toLowerCase(), checkedVault.toLowerCase());
for (const [getter, expected] of [['hollar', result.market.hollar], ['debtToken', result.market.hollarDebt], ['pool', result.market.pool]]) {
  assert.equal((await bufferRead(getter)).toLowerCase(), expected.toLowerCase());
}
const backing = await pub.readContract({address: result.market.hollar, abi: [{type:'function',name:'balanceOf',stateMutability:'view',inputs:[{type:'address'}],outputs:[{type:'uint256'}]}], functionName:'balanceOf',args:[buffer]});
assert.ok(backing >= await bufferRead('ownedCash'));
const exitCount = await pub.readContract({address: checkedVault, abi: artifact('CollateralVault').abi, functionName:'queueUnwind'});
let pending = 0n;
for (let id = 0n; id < exitCount; id++) {
  const position = await pub.readContract({address: buffer, abi: artifact('PropellerMainDebt').abi, functionName:'positions', args:[id + 1n]});
  const request = await pub.readContract({address: checkedVault, abi: artifact('CollateralVault').abi, functionName:'redemptions', args:[id]});
  assert.equal(position[0], 0n, 'exit debt units remain');
  assert.equal(position[1], 0n, 'exit principal debt remains');
  assert.equal(position[2], 0n, 'exit HOLLAR was not claimed');
  assert.equal(position[4].toLowerCase(), request[0].toLowerCase(), 'exit owner changed');
  pending += position[3];
  result.finalBufferExits.push({vault:checkedVault, id:id.toString(), owner:position[4], unpaidSourceClaim:position[3].toString()});
}
const sourcePending = await pub.readContract({address:source,abi:artifact('SubLoop').abi,functionName:'pendingUnwindOf',args:[checkedVault]});
const sourceCost = await pub.readContract({address:source,abi:artifact('SubLoop').abi,functionName:'unwindExecutionCost',args:[checkedVault]});
assert.equal(pending + await bufferRead('activeSourceRemaining'), sourcePending + await bufferRead('unallocatedSource')
  + await bufferRead('unallocatedCost') + sourceCost - await bufferRead('sourceCostCheckpoint'));
await pub.readContract({ address: fees, abi: artifact('PropellerFeeController').abi, functionName: 'validateVault', args: [checkedVault, harvester] });
assert.equal(await pub.readContract({ address: fees, abi: artifact('PropellerFeeController').abi, functionName: 'protocolFeeBps', args: [checkedVault] }), 500);
if (discount) {
  assert.equal(await pub.readContract({ address: discount, abi: artifact('PropellerDiscount').abi, functionName: 'isRegistered', args: [checkedVault] }), true);
  assert.equal(await pub.readContract({ address: discount, abi: artifact('PropellerDiscount').abi, functionName: 'discountBps' }), 0);
}
}
result.checks.deployedCodeMatchesLocalArtifacts = true;
result.checks.proxyImplementationSlots = true;
if (lifecyclePassed) result.checks.exitOwnershipAndPendingSourceClaims = true;
result.verifiedThroughBlock = (await pub.getBlockNumber()).toString();
writeFileSync(FILE, JSON.stringify(result, null, 2) + '\n');
console.log('FINAL ARTIFACT VERIFICATION PASS', result.status, result.checks);
} finally { await api.disconnect(); }
