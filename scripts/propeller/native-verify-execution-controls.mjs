// Read-only artifact verification for the local controls follow-up rehearsal.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync} from 'node:fs';
import {artifact, artifactManifest} from './native-artifacts.mjs';
const require = createRequire(import.meta.url);
const {createPublicClient, http, keccak256} = require('viem');
const {ApiPromise, WsProvider} = require('@polkadot/api');
const input = JSON.parse(readFileSync(process.argv[2]));
const controls = JSON.parse(readFileSync(process.argv[3]));
const output = process.argv[4];
const port = Number(process.env.PROPELLER_LOCAL_PORT);
assert.ok(Number.isInteger(port) && port > 0 && port < 65536 && output);
assert.equal(input.rpc, `http://127.0.0.1:${port}`);
assert.equal(controls.rpc, input.rpc);
const pub = createPublicClient({transport: http(input.rpc, {timeout: 120000}), cacheTime: 0});
const api = await ApiPromise.create({provider: new WsProvider(`ws://127.0.0.1:${port}`), noInitWarn: true});
const results = [];
const read = (address, name, functionName) => pub.readContract({address, abi: artifact(name).abi, functionName});
function executable(bytes) {
  const length = bytes.readUInt16BE(bytes.length - 2);
  assert.ok(length > 0 && length + 2 < bytes.length);
  return bytes.subarray(0, bytes.length - length - 2);
}
async function verify(address, name, allowMetadataDifference = false) {
  const art = artifact(name);
  const raw = await pub.getBytecode({address});
  const deployed = Buffer.from(raw.slice(2), 'hex');
  const expected = Buffer.from(art.deployedBytecode.object.replace(/^0x/, ''), 'hex');
  assert.equal(deployed.length, expected.length, `${name}: length mismatch`);
  assert.ok(deployed.length <= 24576, `${name}: runtime limit`);
  for (const references of Object.values(art.deployedBytecode.immutableReferences ?? {})) {
    for (const {start, length} of references) {
      deployed.fill(0, start, start + length);
      expected.fill(0, start, start + length);
    }
  }
  const exactExceptImmutables = deployed.equals(expected);
  assert.ok(exactExceptImmutables || (allowMetadataDifference && executable(deployed).equals(executable(expected))),
    `${name}: executable bytecode differs from final artifact`);
  results.push({name, address, runtimeBytes: deployed.length, codeHash: keccak256(raw),
    exactExceptImmutables, metadataOnlyDifference: !exactExceptImmutables});
}
try {
  for (const [name, address] of [['SubLoop', controls.sourceImplementation],
    ['CollateralVault', controls.vaultImplementation], ['Harvester', controls.harvester],
    ['ExecutionController', controls.controller], ['SyntheticToken', input.addresses.synth],
    ['PropellerFeeController', input.addresses.fees]]) await verify(address, name);
  const helper = await read(controls.vaultImplementation, 'CollateralVault', 'compoundLogic');
  await verify(helper, 'CompoundLogic');
  const slot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
  for (const [proxy, implementation] of [[input.addresses.source, controls.sourceImplementation],
    [input.addresses.vault, controls.vaultImplementation], [input.addresses.tbtcVault, controls.vaultImplementation]]) {
    const actual = (await api.query.evm.accountStorages(proxy, slot)).toHex();
    assert.equal(`0x${actual.slice(-40)}`.toLowerCase(), implementation.toLowerCase());
  }
  for (const vault of [input.addresses.vault, input.addresses.tbtcVault]) {
    const ledger = await read(vault, 'CollateralVault', 'mainDebt');
    const accounting = await read(vault, 'CollateralVault', 'yieldAccounting');
    // These immutable modules came from the preceding campaign build. Permit
    // only a compiler metadata difference; every executable byte must match.
    await verify(ledger, 'PropellerMainDebt', true);
    await verify(accounting, 'PropellerYieldAccounting', true);
    assert.equal((await read(ledger, 'PropellerMainDebt', 'vault')).toLowerCase(), vault.toLowerCase());
    assert.equal((await read(ledger, 'PropellerMainDebt', 'yieldAccounting')).toLowerCase(), accounting.toLowerCase());
    assert.equal((await read(accounting, 'PropellerYieldAccounting', 'vault')).toLowerCase(), vault.toLowerCase());
    assert.equal((await read(vault, 'CollateralVault', 'executionController')).toLowerCase(), controls.controller.toLowerCase());
    for (const [getter, expected] of [['pool', input.market.pool], ['hollar', input.market.hollar], ['debtToken', input.market.hollarDebt]]) {
      assert.equal((await read(ledger, 'PropellerMainDebt', getter)).toLowerCase(), expected.toLowerCase());
    }
  }
  for (const [name, address] of [['SubLoop', input.addresses.source], ['Harvester', controls.harvester]]) {
    assert.equal((await read(address, name, 'executionController')).toLowerCase(), controls.controller.toLowerCase());
  }
  const result = {status: 'native-control-artifacts-verified', rpc: input.rpc, fork: input.fork,
    verifiedAtBlock: String(await pub.getBlockNumber()), results, artifacts: artifactManifest,
    limitation: 'Local follow-up to a funded campaign, not a fresh exact-artifact production activation rehearsal'};
  writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
  console.log(result.status, results.map(r => `${r.name}: ${r.metadataOnlyDifference ? 'executable match; metadata differs' : 'match except constructor immutables'}`).join('\n'));
} finally { await api.disconnect(); }
