import assert from 'node:assert/strict';
import { test } from 'node:test';
import { toEventSelector, toHex, type Address } from 'viem';
import { JuicerLooper } from '../src/looper.js';
import { CONFIG } from '../src/config.js';
import { feedUpdate, syncDue } from '../src/sync-policy.js';
import { LatestLog, REORG_MARGIN_BLOCKS, newestInChunks, type EvidenceLog } from '../src/log-evidence.js';

const LOOP = '0x0000000000000000000000000000000000000001';
const ETH = '0x00000000000000000000000000000000000000e7';
const BTC = '0x00000000000000000000000000000000000000b7';
const PRIME = '0x000000000000000000000000000000010000002b';
const WETH = '0x0000000000000000000000000000000100000022';
const TBTC = '0x00000000000000000000000000000001000f453d';
const ORACLE = '0x00000000000000000000000000000000000000c0';
const FEED: Record<string, Address> = {
  [PRIME]: '0x00000000000000000000000000000000000000f1', [WETH]: '0x00000000000000000000000000000000000000f2',
  [TBTC]: '0x00000000000000000000000000000000000000f3',
};
const ALLOCATED = toEventSelector('Allocated()');
const CHECKPOINT = toEventSelector('YieldCheckpoint(uint256,uint256)');
// each vault's yield accounting contract
const books = (vault: Address) => (vault === ETH ? '0x00000000000000000000000000000000000000e8'
  : '0x00000000000000000000000000000000000000b8') as Address;
const EVERY = BigInt(CONFIG.SYNC_EVERY);

function chain(allocationEvents = true) {
  const c = {
    block: 1_000n,
    time: 1_000_000n,
    timestamps: new Map<bigint, bigint>(),
    rounds: Object.fromEntries([PRIME, WETH, TBTC].map(a => [a, {answer: 100n, updatedAt: 990_000n}])) as
      Record<string, {answer: bigint; updatedAt: bigint}>,
    logs: [] as any[],
    calls: [] as string[],
    getLogs: 0,
    oracleDown: false,
    mine(seconds = 6n) { c.block += 1n; c.time += seconds; c.timestamps.set(c.block, c.time); },
    update(asset: Address) { c.mine(); c.rounds[asset] = {answer: c.rounds[asset].answer + 1n, updatedAt: c.time}; },
    log(address: Address, topic: string) {
      c.mine();
      c.logs.push({address, topics: [topic], data: '0x', blockNumber: toHex(c.block), logIndex: '0x0',
        transactionHash: toHex(c.block, {size: 32}), removed: false});
    },
    allocationEvents,
  };
  return c;
}
type Chain = ReturnType<typeof chain>;

function keeper(c: Chain, name = 'k0') {
  const k = Object.create(JuicerLooper.prototype) as any;
  Object.assign(k, {cycle: 0, subLoop: LOOP, vaults: [ETH, BTC], harvester: '', pool: LOOP});
  k.read = async (_abi: unknown, address: string, fn: string, args: any[] = []) => {
    if (c.oracleDown && ['ADDRESSES_PROVIDER', 'latestRoundData'].includes(fn)) throw new Error('oracle unavailable');
    const views: Record<string, () => unknown> = {
      prime: () => PRIME, asset: () => address === ETH ? WETH : TBTC, ADDRESSES_PROVIDER: () => LOOP,
      getPriceOracle: () => ORACLE, getSourceOfAsset: () => FEED[args[0].toLowerCase()], yieldAccounting: () => books(address as Address),
      latestRoundData: () => {
        const asset = Object.keys(FEED).find(a => FEED[a] === address.toLowerCase())!;
        return [1n, c.rounds[asset].answer, 0n, c.rounds[asset].updatedAt, 1n];
      },
    };
    assert.ok(fn in views, `unexpected read ${fn}`);
    return views[fn]();
  };
  k.publicClient = {
    getBlockNumber: async () => c.block,
    getBlock: async ({blockNumber}: {blockNumber: bigint}) => ({timestamp: c.timestamps.get(blockNumber)}),
    request: async ({method, params: [filter]}: any) => {
      assert.equal(method, 'eth_getLogs');
      ++c.getLogs;
      const addresses = [filter.address].flat().map((a: string) => a.toLowerCase());
      return c.logs.filter(l => addresses.includes(l.address.toLowerCase()) && filter.topics[0].includes(l.topics[0])
        && BigInt(l.blockNumber) >= BigInt(filter.fromBlock) && BigInt(l.blockNumber) <= BigInt(filter.toBlock));
    },
  };
  k.poke = async (_abi: unknown, address: Address, fn: string) => {
    c.calls.push(`${name}:${fn}:${address === ETH ? 'eth' : 'btc'}`);
    // sync() allocates, and the accounting records that
    if (c.allocationEvents) c.log(books(address), ALLOCATED);
    else c.mine();
    return true;
  };
  return k;
}

async function sync(c: Chain, k: any, skip: Address[] = []) {
  c.calls = [];
  c.getLogs = 0;
  const log = console.log;
  console.log = () => {};
  try { await k.syncVaults(new Set(skip), c.time); } finally { console.log = log; }
  return c.calls;
}

test('a sync is due after an unsynced update or once SYNC_EVERY has passed', () => {
  assert.equal(syncDue(100n, 100n, 101n, 3600n), true, 'a sync in the update\'s second may precede it');
  assert.equal(syncDue(101n, 100n, 102n, 3600n), false);
  assert.equal(syncDue(101n, undefined, 3700n, 3600n), false);
  assert.equal(syncDue(101n, undefined, 3701n, 3600n), true);
  const first = feedUpdate(undefined, 5n, 90n, 100n);
  assert.equal(first.at, 90n);
  assert.equal(feedUpdate(first, 5n, 90n, 120n).at, 90n, 'an unchanged round is not an update');
  assert.equal(feedUpdate(first, 6n, 95n, 120n).at, 95n);
  assert.equal(feedUpdate(first, 6n, 90n, 120n).at, 120n, 'a moved answer under an old updatedAt counts when seen');
});

test('oracle updates sync only the vaults whose prices moved, once each', async () => {
  const c = chain();
  const k = keeper(c);
  assert.deepEqual(await sync(c, k), ['k0:sync:eth', 'k0:sync:btc'], 'nothing proves a sync since the last updates');
  assert.deepEqual(await sync(c, k), []);
  assert.equal(c.getLogs, 0, 'its own syncs need no log scan');
  c.update(WETH);
  assert.deepEqual(await sync(c, k), ['k0:sync:eth']);
  c.update(TBTC);
  assert.deepEqual(await sync(c, k), ['k0:sync:btc']);
  c.update(PRIME);
  assert.deepEqual(await sync(c, k), ['k0:sync:eth', 'k0:sync:btc']);
  assert.deepEqual(await sync(c, k), []);
});

test('an allocation that already followed the update is not repeated, whoever ran it', async () => {
  const c = chain();
  const k = keeper(c);
  await sync(c, k);
  c.update(PRIME);
  // another operator's sync and a deposit both allocate
  c.log(books(ETH), ALLOCATED);
  c.log(books(BTC), ALLOCATED);
  assert.deepEqual(await sync(c, k), []);
  c.update(PRIME);
  c.log(books(ETH), ALLOCATED);
  // minting events and anything the vault itself emits are not the allocation record
  c.log(books(BTC), CHECKPOINT);
  c.log(BTC, ALLOCATED);
  assert.deepEqual(await sync(c, k), ['k0:sync:btc']);
});

test('without updates the timer syncs every SYNC_EVERY seconds', async () => {
  const c = chain();
  const k = keeper(c);
  await sync(c, k);
  c.mine(EVERY - 60n);
  assert.deepEqual(await sync(c, k), []);
  c.mine(60n);
  assert.deepEqual(await sync(c, k), ['k0:sync:eth', 'k0:sync:btc']);
});

test('two operators sync each update once between them', async () => {
  const c = chain();
  const k0 = keeper(c, 'k0'), k1 = keeper(c, 'k1');
  assert.deepEqual(await sync(c, k0), ['k0:sync:eth', 'k0:sync:btc']);
  assert.deepEqual(await sync(c, k1), [], 'the second operator finds the first one\'s syncs');
  c.update(WETH);
  assert.deepEqual(await sync(c, k1), ['k1:sync:eth']);
  assert.deepEqual(await sync(c, k0), []);
  c.mine(EVERY / 2n);
  c.update(PRIME);
  assert.deepEqual(await sync(c, k0), ['k0:sync:eth', 'k0:sync:btc']);
  c.mine(EVERY / 2n + 60n);
  assert.deepEqual(await sync(c, k1), [], 'the timer counts from the newest sync by either');
});

test('a restarted keeper finds the last allocation on-chain; without its events it syncs once per update', async () => {
  const c = chain();
  await sync(c, keeper(c));
  assert.deepEqual(await sync(c, keeper(c)), []);
  const quiet = chain(false);
  const k = keeper(quiet);
  assert.deepEqual(await sync(quiet, k), ['k0:sync:eth', 'k0:sync:btc']);
  assert.deepEqual(await sync(quiet, k), [], 'its own memory covers what no event shows');
});

test('allocation evidence survives a reorg of its newest blocks by searching again', async () => {
  const at = (block: bigint): EvidenceLog => ({block, index: 0, topics: [], data: '0x', tx: '0x'});
  let logs = [at(10n), at(95n)];
  const newest = (from: bigint, to: bigint) =>
    newestInChunks(async (lo, hi) => logs.filter(l => l.block >= lo && l.block <= hi), from, to);
  const tracker = new LatestLog(1_000n);
  assert.equal((await tracker.find(newest, 100n))?.block, 95n);
  logs = [at(10n)];
  assert.equal((await tracker.find(newest, 101n))?.block, 10n, 'a vanished recent log is not trusted');
  logs.push(at(99n + REORG_MARGIN_BLOCKS));
  assert.equal((await tracker.find(newest, 200n))?.block, 99n + REORG_MARGIN_BLOCKS);
  assert.equal((await new LatestLog(50n).find(newest, 1_000n)), undefined, 'the lookback bounds the search');
});

test('a composite feed moving without a newer updatedAt still triggers one sync', async () => {
  const c = chain();
  const k = keeper(c);
  await sync(c, k);
  c.mine();
  c.rounds[PRIME] = {...c.rounds[PRIME], answer: 101n};
  assert.deepEqual(await sync(c, k), ['k0:sync:eth', 'k0:sync:btc']);
  assert.deepEqual(await sync(c, k), []);
});

test('unreadable oracles fall back to the timer; skipped vaults are not synced', async () => {
  const c = chain();
  const k = keeper(c);
  assert.deepEqual(await sync(c, k, [ETH]), ['k0:sync:btc']);
  c.oracleDown = true;
  c.update(PRIME);
  assert.deepEqual(await sync(c, k, [ETH]), [], 'the update is invisible');
  c.mine(EVERY);
  assert.deepEqual(await sync(c, k, [ETH]), ['k0:sync:btc']);
});
