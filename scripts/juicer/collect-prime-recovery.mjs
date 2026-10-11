// Public read-only Neckwork collection, paginated by closed UTC day. Keep raw
// responses in the supplied cache; hash them and retain the extracted rows.
import assert from 'node:assert/strict';
import {mkdirSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';

const [from, toExclusive, directory] = process.argv.slice(2);
assert.ok(directory, 'usage: collect-prime-recovery.mjs from-date to-exclusive-date cache-directory');
const start = Date.parse(`${from}T00:00:00Z`), end = Date.parse(`${toExclusive}T00:00:00Z`);
assert.ok(Number.isFinite(start) && end > start && end <= Date.now());
mkdirSync(directory, {recursive: true});
const base = 'https://hydration-explorer.neckwork.net/api';
const sha = b => createHash('sha256').update(b).digest('hex');
const sources = [];
async function get(key, path) {
  const file = resolve(directory, `${key}.json`), url = base + path;
  let response;
  if (existsSync(file)) response = JSON.parse(readFileSync(file));
  else {
    const r = await fetch(url, {signal: AbortSignal.timeout(45000)});
    assert.ok(r.ok, `${r.status}: ${url}`);
    response = {url, retrievedAt: new Date().toISOString(), data: await r.json()};
    writeFileSync(file, JSON.stringify(response) + '\n');
  }
  assert.equal(response.url, url, 'cache belongs to another request');
  sources.push({file: `${key}.json`, url, retrievedAt: response.retrievedAt, sha256: sha(readFileSync(file))});
  return response.data;
}
const indexer = await get('indexer', '/indexer');
const pool = await get('pool143', '/explorer/pool/143');
const treasuryDca = await get('dca-37930', '/explorer/dca/37930?limit=5');
const rows = [], days = [], seen = new Set();
for (let t = start; t < end; t += 86400000) {
  const date = new Date(t).toISOString().slice(0, 10);
  let count = 0, exhausted = false;
  for (let offset = 0; offset <= 2500; offset += 250) {
    const page = await get(`${date}-${offset}`, `/explorer/activity?asset=43&type=trade&limit=250&offset=${offset}&from=${date}&to=${date}`);
    assert.ok(Array.isArray(page));
    for (const r of page) {
      assert.equal(r.timestamp.slice(0, 10), date, 'server did not respect date filter');
      const key = `${r.blockHeight}:${r.eventIndex}:${r.type}`;
      assert.ok(!seen.has(key), `duplicate or unstable pagination: ${key}`);
      seen.add(key); count++;
      rows.push({block: r.blockHeight, event: r.eventIndex, extrinsic: r.extrinsicIndex,
        timestamp: r.timestamp, type: r.type, account: r.who?.address,
        tag: r.who?.tag?.id ?? null, assetIn: r.assetIn?.assetId,
        assetOut: r.assetOut?.assetId, amountIn: r.amountIn, amountOut: r.amountOut,
        valueUsd: r.valueUsd, dca: r.dca, dcaScheduleId: r.dcaScheduleId ?? null});
    }
    if (page.length < 250) { exhausted = true; break; }
  }
  // A capped day is retained as explicitly partial; analysis must not count
  // its absent rows as zero flow or use it as a complete daily observation.
  days.push({date, rows: count, exhausted});
  console.log(date, count, exhausted ? 'complete' : 'PARTIAL: API page cap');
}
rows.sort((a, b) => a.block - b.block || a.event - b.event);
const snapshots = [];
for (let t = start; t < end; t += 86400000) {
  const date = new Date(t).toISOString().slice(0, 10);
  const s = await get(`reserves-${date}`, `/explorer/pool/143/snapshots?resolution=grid&stepBlocks=600&fromTs=${t / 1000}&toTs=${(t + 86400000) / 1000 - 1}&limit=1000`);
  assert.equal(s.poolId, 143);
  assert.equal(s.coverage.truncated, false);
  assert.equal(s.coverage.missingCount, 0);
  assert.equal(s.coverage.returned, s.points.length);
  assert.equal(s.coverage.expected, s.points.length);
  assert.ok(s.points.every(p => p.t >= t / 1000 && p.t < (t + 86400000) / 1000));
  snapshots.push(s);
  console.log('reserves', date, s.points.length);
}
// Cross-check repeated flows against actual pool events. Representative blocks
// do not turn the entire asset endpoint feed into an exhaustive pool-leg feed.
const treasury = rows.filter(r => r.tag === 'treasury' && r.assetIn === 43 && r.dca);
const post = rows.filter(r => r.timestamp >= '2026-09-26' && r.assetOut === 43 && r.assetIn !== 1043);
const actors = [...new Set(post.map(r => r.account))];
const selected = [treasury[0], treasury.at(-1), ...actors.map(account => post
  .filter(r => r.account === account).sort((a, b) => b.valueUsd - a.valueUsd)[0])]
  .filter(Boolean).slice(0, 15);
const examples = [];
for (const r of selected) {
  const block = await get(`block-${r.block}`, `/explorer/block/${r.block}`);
  const poolEvents = block.events.filter(e => e.name.startsWith('Stableswap.') && e.args?.poolId === 143);
  examples.push({activity: r, hash: block.hash, eventsShown: block.eventsShown,
    eventCount: block.eventCount, poolEvents,
    events: block.events.filter(e => /DCA\.|Router\.|Stableswap\.|Wormhole|EVM.Executed/.test(e.name))});
}
const result = {from, toExclusive, api: base, collectedAt: new Date().toISOString(),
  indexer, pool, treasuryDca, days, sources, rows, snapshots, examples,
  limitation: 'Asset endpoint actions, not an exhaustive pool-leg index. Wrapper conversions and unresolved endpoints must be excluded. Opposite-direction flow is not by itself proof of arbitrage.'};
writeFileSync(resolve(directory, 'history.json'), JSON.stringify(result) + '\n');
console.log('saved', rows.length, 'rows to', resolve(directory, 'history.json'));
