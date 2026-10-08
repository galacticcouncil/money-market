import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { artifact, artifactManifest } from './native-artifacts.mjs';
const require = createRequire(new URL('../../package.json', import.meta.url));
const { createPublicClient, http, keccak256 } = require('viem');
const { ApiPromise, WsProvider } = require('@polkadot/api');
const FILE = process.argv[2] || '/tmp/propeller-buffer-native-result.json';
const PORT = Number(process.env.PROPELLER_LOCAL_PORT || 8142);
assert.ok(Number.isInteger(PORT) && PORT > 0 && PORT <= 65535);
const result = JSON.parse(readFileSync(FILE, 'utf8'));
assert.equal(result.rpc, `http://127.0.0.1:${PORT}`, 'result belongs to another local fork');
const lifecyclePassed = result.status === 'native-multi-user-multi-vault-campaign-passed';
assert.ok(lifecyclePassed || ['native-entry-blocked-by-strict-slippage',
  'core-stack-deployed-and-fees-wired', 'combined-stack-deployed-and-wired'].includes(result.status));
const pub = createPublicClient({ transport: http(`http://127.0.0.1:${PORT}`, { timeout: 120_000 }), cacheTime: 0 });
const api = await ApiPromise.create({ provider: new WsProvider(`ws://127.0.0.1:${PORT}`), noInitWarn: true });

try {
async function verifyCode(address, name) {
  const code = await pub.getBytecode({ address });
  const art = artifact(name);
  const deployed = Buffer.from(code.slice(2), 'hex');
  const expected = Buffer.from(art.deployedBytecode.object.replace(/^0x/, ''), 'hex');
  assert.equal(deployed.length, expected.length);
  assert.ok(deployed.length <= 24576);
  for (const references of Object.values(art.deployedBytecode.immutableReferences ?? {})) {
    for (const { start, length } of references) {
      deployed.fill(0, start, start + length);
      expected.fill(0, start, start + length);
    }
  }
  assert.ok(deployed.equals(expected), `${name}: deployed bytecode differs from the selected artifact`);
  return { address, codeHash: keccak256(code), runtimeBytes: deployed.length };
}
for (const deployment of result.deployments) {
  const name = deployment.label.endsWith('.proxy') ? 'ERC1967Proxy'
    : deployment.label.startsWith('PropellerMainDebt') ? 'PropellerMainDebt' : deployment.label;
  assert.equal((await verifyCode(deployment.address, name)).codeHash, deployment.codeHash);
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
if (!lifecyclePassed && result.status !== 'core-stack-deployed-and-fees-wired') assert.equal(result.verifiedPolicy.slippagePpm, 10000);
const helper = await pub.readContract({ address: vaultImpl, abi: artifact('CollateralVault').abi, functionName: 'compoundLogic' });
assert.equal((await pub.getBytecode({address: helper})).toLowerCase(), artifact('CompoundLogic').deployedBytecode.object.toLowerCase());
result.checks.constructorHelperMatchesArtifact = true;
const SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
for (const [proxy, implementation] of [[vault, vaultImpl], [source, subImpl], [result.addresses.tbtcVault, vaultImpl]].filter(([proxy]) => proxy)) {
  const slot = (await api.query.evm.accountStorages(proxy, SLOT)).toHex();
  assert.equal(`0x${slot.slice(-40)}`.toLowerCase(), implementation.toLowerCase());
}
result.finalBufferExits = [];
result.verifiedYieldModules = [];
for (const checkedVault of [vault, result.addresses.tbtcVault].filter(Boolean)) {
const buffer = await pub.readContract({ address: checkedVault, abi: artifact('CollateralVault').abi, functionName: 'mainDebt' });
const bufferRead = (functionName, args = []) => pub.readContract({address: buffer, abi: artifact('PropellerMainDebt').abi, functionName, args});
assert.equal((await bufferRead('vault')).toLowerCase(), checkedVault.toLowerCase());
const module = await bufferRead('yieldAccounting');
assert.equal((await pub.readContract({address: checkedVault, abi: artifact('CollateralVault').abi, functionName:'yieldAccounting'})).toLowerCase(), module.toLowerCase());
assert.equal((await pub.readContract({address: module, abi: artifact('PropellerYieldAccounting').abi, functionName:'vault'})).toLowerCase(), checkedVault.toLowerCase());
result.verifiedYieldModules.push({vault: checkedVault, ...await verifyCode(module, 'PropellerYieldAccounting')});
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
  assert.equal(await bufferRead('surplusOf', [id]), 0n, 'claimable exit HOLLAR was not claimed');
  assert.equal(position[4].toLowerCase(), request[0].toLowerCase(), 'exit owner changed');
  pending += position[3];
  result.finalBufferExits.push({vault:checkedVault, id:id.toString(), owner:position[4], unpaidSourceClaim:position[3].toString(), reservedCash:position[2].toString()});
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
result.build.artifacts = { ...result.build.artifacts, ...artifactManifest };
writeFileSync(FILE, JSON.stringify(result, null, 2) + '\n');
console.log('FINAL ARTIFACT VERIFICATION PASS', result.status, result.checks);
} finally { await api.disconnect(); }
