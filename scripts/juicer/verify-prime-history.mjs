// Independent read-only archive RPC cross-check of representative Neckwork
// observations, including both sides of the LP issuance change.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
const require = createRequire(import.meta.url);
const {ApiPromise, WsProvider} = require('@polkadot/api');
const [historyFile, output] = process.argv.slice(2);
assert.ok(output);
const bytes = readFileSync(historyFile), history = JSON.parse(bytes);
const points = history.snapshots.flatMap(s => s.points);
const change = points.findIndex((p, i) => i > 0 && p.issuance !== points[i - 1].issuance);
assert.ok(change > 0);
const selected = [points[0], points[change - 1], points[change], points.at(-1)];
const endpoint = 'wss://hdx.tarn.hydration.cloud';
const api = await ApiPromise.create({provider: new WsProvider(endpoint), noInitWarn: true});
const checked = [];
try {
  for (const p of selected) {
    const hash = (await api.rpc.chain.getBlockHash(p.block)).toHex();
    assert.equal(hash, p.hash);
    const at = await api.at(hash), account = history.pool.account.address;
    const results = await Promise.all([
      at.call.currenciesApi.freeBalance(43, account), at.call.currenciesApi.freeBalance(222, account),
      at.query.stableswap.poolPegs(143), at.query.tokens.totalIssuance(143),
      at.query.timestamp.now(), at.query.stableswap.pools(143),
    ]);
    assert.deepEqual(results.slice(0, 2).map(x => x.toString()), p.reserves);
    const pegs = results[2].toJSON().current;
    assert.deepEqual(pegs.map(pair => pair.map(v => BigInt(v).toString())), p.pegs.map(v => [v.num, v.den]));
    assert.equal(results[3].toString(), p.issuance);
    assert.equal(Number(results[4].toString()) / 1000, p.t);
    assert.equal(results[5].unwrap().toJSON().fee, p.feePermill);
    checked.push({block: p.block, hash, time: p.time, reserves: p.reserves,
      pegs: p.pegs, issuance: p.issuance, feePermill: p.feePermill});
    console.log('verified', p.block, p.time);
  }
  writeFileSync(output, JSON.stringify({endpoint, retrievedAt: new Date().toISOString(),
    historySha256: createHash('sha256').update(bytes).digest('hex'), checked}, null, 2) + '\n');
} finally {
  await api.disconnect();
}
