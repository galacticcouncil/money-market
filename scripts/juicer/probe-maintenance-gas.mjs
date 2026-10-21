// Read-only local-fork probes. No signing key or transaction submission.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
const require = createRequire(import.meta.url);
const { encodeFunctionData, parseAbi } = require('viem');
const [deploymentFile, outputFile] = process.argv.slice(2);
assert.ok(outputFile, 'usage: probe-maintenance-gas.mjs native-deployment.json output.json');
const deployment = JSON.parse(readFileSync(deploymentFile));
assert.match(deployment.rpc, /^http:\/\/127\.0\.0\.1:\d+$/);
let id = 0;
async function rpc(method, params = []) {
  const response = await fetch(deployment.rpc, { method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
    signal: AbortSignal.timeout(30000) });
  assert.ok(response.ok);
  return response.json();
}
const block = (await rpc('eth_blockNumber')).result;
const gasPrice = (await rpc('eth_gasPrice')).result;
assert.ok(block && gasPrice);
const rows = [];
for (const asset of ['vault', 'tbtcVault']) for (const functionName of ['maintainPeg', 'pokeSettle', 'rebalance']) {
  const to = deployment.addresses[asset];
  const abi = parseAbi([`function ${functionName}()`]);
  const data = encodeFunctionData({ abi, functionName });
  const trials = [];
  const probe = async gas => {
    const result = await rpc('eth_call', [{ to, data, gas: `0x${gas.toString(16)}`,
      from: '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266' }, block]);
    if (result.error && result.error.code !== 3 && !/^execution reverted/.test(result.error.message ?? '')) {
      throw new Error(JSON.stringify(result.error));
    }
    trials.push({ gas, success: !result.error, error: result.error?.message });
    return !result.error;
  };
  let low = 21000, high = 16777216;
  const executable = await probe(high);
  if (executable) while (high - low > high / 20) {
    const mid = Math.floor((low + high) / 2);
    if (await probe(mid)) high = mid; else low = mid;
  }
  rows.push({ asset, to, functionName, executable,
    gasUpperBound: executable ? high : null, trials });
  writeFileSync(outputFile, JSON.stringify({ rpc: deployment.rpc, block, gasPrice,
    originalFork: deployment.fork,
    scope: 'Read-only eth_call binary search on existing local runtime-447 fork, with its prior campaign state. Gas bounds are state-specific, not receipt gas or annual cost predictions.',
    rows }, null, 2) + '\n');
  console.log(asset, functionName, executable ? high : 'reverted; keeper simulation should skip');
}
