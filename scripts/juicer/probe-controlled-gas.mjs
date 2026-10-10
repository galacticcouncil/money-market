// Read-only gas calibration of controlled actions in an existing LOCAL fixture.
// No wallet, signing key, transactions, state overrides or relaxed gas ceiling.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync} from 'node:fs';
import {artifact, maxTransactionGas} from './native-artifacts.mjs';
const require = createRequire(import.meta.url);
const {createPublicClient, http, encodeFunctionData, decodeAbiParameters, parseAbiParameters} = require('viem');
const {ApiPromise, WsProvider} = require('@polkadot/api');
const [deploymentFile, controlsFile, outputFile] = process.argv.slice(2);
assert.ok(outputFile, 'usage: probe-controlled-gas.mjs native-deploy.json native-controls.json output.json');
const deployment = JSON.parse(readFileSync(deploymentFile)), controls = JSON.parse(readFileSync(controlsFile));
assert.match(deployment.rpc, /^http:\/\/127\.0\.0\.1:\d+$/);
assert.equal(deployment.rpc, controls.rpc);
const pub = createPublicClient({transport: http(deployment.rpc, {timeout: 180000}), cacheTime: 0});
const api = await ApiPromise.create({provider: new WsProvider(deployment.rpc.replace('http:', 'ws:')), noInitWarn: true});
const ctl = artifact('ExecutionController').abi;
const account = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
const result = {rpc: deployment.rpc, scope: 'State-specific read-only native bounds. Productive and zero-work paths are distinguished; no annual gas guarantee.', rows: []};
const save = () => writeFileSync(outputFile, JSON.stringify(result, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2) + '\n');
try {
  const head = await pub.getBlock();
  assert.ok(head.timestamp >= 1_000_000_000_000n, 'local adapter expects Chopsticks millisecond timestamps');
  const quoteBlock = head.number - 1n;
  const quotedHash = (await api.query.ethereum.blockHash(quoteBlock.toString())).toHex();
  result.block = head.number;
  result.quoteBlock = quoteBlock;
  result.gasPrice = await pub.getGasPrice();
  for (const [label, target, name, fn] of [
    ['source.ramp', deployment.addresses.source, 'SubLoop', 'pokeBorrow'],
    ['ETH.rebalance', deployment.addresses.vault, 'CollateralVault', 'rebalance'],
    ['BTC.rebalance', deployment.addresses.tbtcVault, 'CollateralVault', 'rebalance'],
  ]) {
    const data = encodeFunctionData({abi: artifact(name).abi, functionName: fn});
    const trials = [];
    let measured;
    try {
      const {result: [returned, fills]} = await pub.simulateContract({account, address: controls.controller,
        abi: ctl, functionName: 'preview', args: [target, data], blockNumber: quoteBlock, gas: maxTransactionGas});
      const work = decodeAbiParameters(parseAbiParameters('uint256'), returned)[0];
      const quotes = fills.map(f => ({lane: f.lane, amountIn: f.amountIn, minOut: f.amountOut * 9998n / 10000n}));
      const args = [target, data, quoteBlock, quotedHash, head.timestamp / 1000n + 60n, quotes];
      const probe = async gas => {
        try { await pub.simulateContract({account, address: controls.controller, abi: ctl,
          functionName: 'execute', args, blockNumber: head.number, gas}); trials.push({gas, success: true}); return true; }
        catch (e) {
          let cause = e, reverted = false;
          while (cause) { reverted ||= cause.name === 'ExecutionRevertedError' || cause.code === 3; cause = cause.cause; }
          if (!reverted) throw e;
          trials.push({gas, success: false, error: e.shortMessage ?? e.message}); return false;
        }
      };
      let low = 21000n, high = maxTransactionGas;
      if (await probe(high)) {
        while (high - low > high / 20n) { const mid = (high + low) / 2n; if (await probe(mid)) high = mid; else low = mid; }
        measured = {work, fills, gasUpperBound: high, allowance: (high * 120n + 99n) / 100n};
      } else measured = {work, fills, executable: false};
    } catch (e) { measured = {error: e.shortMessage ?? e.message}; }
    result.rows.push({label, target, ...measured, trials}); save();
    console.log(label, JSON.stringify(measured, (_, v) => typeof v === 'bigint' ? v.toString() : v));
  }
} finally { await api.disconnect(); }
