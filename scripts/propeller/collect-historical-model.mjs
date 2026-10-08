// Read-only, cached evidence for the historical modeling campaign.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {mkdirSync, readFileSync, writeFileSync, existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
const require = createRequire(import.meta.url);
const {createPublicClient, http, parseAbi} = require('viem');
const [from = '2026-07-04', to = '2026-10-02', dir = '/tmp/propeller-historical-model'] = process.argv.slice(2);
const start = Date.parse(from) / 1000, end = Date.parse(to) / 1000;
assert.ok(end > start && end * 1000 <= Date.now());
mkdirSync(dir, {recursive: true});
const base = 'https://hydration-explorer.neckwork.net/api';
const rpc = 'https://hdx.tarn.hydration.cloud';
const client = createPublicClient({transport: http(rpc, {timeout: 45000, retryCount: 2})});
const poolAddress = '0x1b02E051683b5cfaC5929C25E84adb26ECf87B38';
const abi = parseAbi([
  'function ADDRESSES_PROVIDER() view returns(address)',
  'function getPriceOracle() view returns(address)',
  'function getAssetsPrices(address[]) view returns(uint256[])',
  'function getReserveNormalizedIncome(address) view returns(uint256)',
  'function getReserveNormalizedVariableDebt(address) view returns(uint256)'
]);
const token = id => `0x${((1n << 32n) + BigInt(id)).toString(16).padStart(40, '0')}`;
const assets = [token(34), token(1000765), token(43), '0x531a654d1696ED52e7275A8cede955E82620f99a'];
const sources = [];
const json = x => JSON.stringify(x, (_, v) => typeof v === 'bigint' ? v.toString() : v) + '\n';
async function cache(key, request, get) {
  const file = resolve(dir, key + '.json');
  if (!existsSync(file)) {
    const data = await get();
    writeFileSync(file, json({request, retrievedAt: new Date().toISOString(), data}));
  }
  const bytes = readFileSync(file), record = JSON.parse(bytes);
  assert.deepEqual(record.request, request);
  sources.push({file: key + '.json', request, retrievedAt: record.retrievedAt,
    sha256: createHash('sha256').update(bytes).digest('hex')});
  return record.data;
}
async function api(key, path) {
  const url = base + path;
  return cache(key, {url}, async () => {
    const r = await fetch(url, {signal: AbortSignal.timeout(45000)});
    assert.ok(r.ok, `${r.status} ${url}`); return r.json();
  });
}
const candles = {};
for (const [name, id] of [['ETH',34],['BTC',1000765]]) {
  candles[name] = await api(name, `/candles?baseId=${id}&quoteId=10&interval=1h&from=${start}&to=${end}`);
  console.log(name, candles[name].length, 'candles');
}
const days = [];
for (let t = start - 86400; t <= end; t += 86400) days.push(t);
const snapshots = [], markets = [];
// Modest concurrency; every failed or incomplete day fails the collection.
let cursor = 0;
await Promise.all(Array.from({length: 4}, async () => {
  while (cursor < days.length) {
    const t = days[cursor++], date = new Date(t * 1000).toISOString().slice(0,10);
    const s = await api('pool-' + date, `/explorer/pool/143/snapshots?resolution=grid&stepBlocks=600&fromTs=${t}&toTs=${t + 86399}&limit=1000`);
    assert.deepEqual(s.assets.map(x => x.assetId), [43,222]);
    assert.equal(s.coverage.missingCount, 0); assert.equal(s.coverage.truncated, false);
    assert.equal(s.points.length, s.coverage.expected); assert.ok(s.points.length);
    snapshots.push(s);
    const point = t < start ? s.points.at(-1) : s.points[0];
    const blockNumber = BigInt(point.block);
    const market = await cache('market-' + date, {rpc, block: point.block, hash: point.hash, assets}, async () => {
      const read = (address, functionName, args = []) => client.readContract({address, abi, functionName, args, blockNumber});
      const provider = await read(poolAddress, 'ADDRESSES_PROVIDER');
      const oracle = await read(provider, 'getPriceOracle');
      const [prices, incomeIndex, debtIndex, header] = await Promise.all([
        read(oracle, 'getAssetsPrices', [assets]),
        read(poolAddress, 'getReserveNormalizedIncome', [assets[2]]),
        read(poolAddress, 'getReserveNormalizedVariableDebt', [assets[3]]),
        client.getBlock({blockNumber})
      ]);
      assert.equal(Number(header.timestamp), point.t);
      // Frontier EVM and Substrate hashes have different domains. The height
      // and timestamp are matched; retain both hashes, do not equate them.
      return {block: point.block, substrateHash: point.hash, evmHash: header.hash,
        t: point.t, provider, oracle, prices, incomeIndex, debtIndex};
    });
    markets.push(market);
    console.log(date, s.points.length, 'pool observations', 'oracle', market.prices.join(','));
  }
}));
snapshots.sort((a,b) => a.points[0].t - b.points[0].t); markets.sort((a,b) => a.t-b.t);
if (process.argv.includes('--dense')) {
  const points = snapshots.flatMap(s => s.points).filter(p => p.t >= start && p.t < end);
  const existing = new Set(markets.map(m => m.block));
  cursor = 0;
  const sampled = [...markets];
  await Promise.all(Array.from({length: 4}, async () => {
    while (cursor < points.length) {
      const p = points[cursor++];
      if (existing.has(p.block)) continue;
      const day = sampled.filter(m => m.t <= p.t).at(-1);
      const market = await cache('market-block-' + p.block,
        {rpc, block:p.block, hash:p.hash, assets, oracle:day.oracle}, async () => {
          const read = (address,functionName,args) => client.readContract({address,abi,functionName,args,blockNumber:BigInt(p.block)});
          const [prices,incomeIndex,debtIndex] = await Promise.all([
            read(day.oracle,'getAssetsPrices',[assets]),
            read(poolAddress,'getReserveNormalizedIncome',[assets[2]]),
            read(poolAddress,'getReserveNormalizedVariableDebt',[assets[3]])
          ]);
          return {block:p.block,substrateHash:p.hash,t:p.t,provider:day.provider,oracle:day.oracle,
            prices,incomeIndex,debtIndex};
        });
      markets.push(market);
      if (cursor % 200 === 0) console.log('dense market observations', cursor, '/', points.length);
    }
  }));
  markets.sort((a,b) => a.t-b.t);
}
sources.sort((a,b) => a.file.localeCompare(b.file));
writeFileSync(resolve(dir,'history.json'), json({from,to,start,end,collectedAt:new Date().toISOString(),candles,snapshots,markets,sources}));
console.log('saved', resolve(dir,'history.json'));
