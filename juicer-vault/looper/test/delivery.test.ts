import assert from 'node:assert/strict';
import { test } from 'node:test';
import { CONFIG } from '../src/config.js';
import { JuicerLooper } from '../src/looper.js';

const VAULT = '0x0000000000000000000000000000000000000002';
const LEDGER = '0x0000000000000000000000000000000000000003';
const OWNER = '0x00000000000000000000000000000000000000aa';

type Request = { active: boolean; settled: bigint; surplus: bigint; debtShare?: bigint; repaid?: bigint };

function keeper(requests: Request[]) {
  const calls: Array<[string, string, unknown[]]> = [];
  const k = Object.create(JuicerLooper.prototype) as any;
  k.read = async (_abi: unknown, address: string, fn: string, args: bigint[] = []) => {
    if (fn === 'queueHead') return BigInt(requests.length);
    if (fn === 'mainDebt') return LEDGER;
    const r = requests[Number(args[0])];
    if (fn === 'redemptions') return [OWNER, 0n, 0n, r.debtShare ?? 0n, 0n, r.repaid ?? 0n, r.settled, 0n, r.active];
    if (fn === 'surplusOf') return r.surplus;
    throw new Error(`unexpected read ${fn} on ${address}`);
  };
  k.poke = async (_abi: unknown, address: string, fn: string, _label: string, args: unknown[]) => {
    calls.push([address, fn, args]);
    const r = requests[Number(args[0])];
    if (fn === 'claim') { r.active = false; r.settled = 0n; }
    if (fn === 'claimSurplus') r.surplus = 0n;
    return true;
  };
  return { k, calls };
}

async function delivering<T>(on: boolean, run: () => Promise<T>): Promise<T> {
  const previous = CONFIG.DELIVER_CLAIMS;
  CONFIG.DELIVER_CLAIMS = on;
  try { return await run(); } finally { CONFIG.DELIVER_CLAIMS = previous; }
}

test('settled claims and exit surplus are pushed to their owners', () => delivering(true, async () => {
  const requests = [
    { active: false, settled: 0n, surplus: 0n },
    { active: true, settled: 5n, surplus: 10n ** 17n },
    { active: true, settled: 7n, surplus: 1n },
  ];
  const { k, calls } = keeper(requests);
  await k.deliver(VAULT);
  assert.deepEqual(calls, [
    [VAULT, 'claim', [1n, OWNER, 2n ** 256n - 1n]],
    [LEDGER, 'claimSurplus', [1n]],
    [VAULT, 'claim', [2n, OWNER, 2n ** 256n - 1n]],
  ], 'dust surplus below the minimum is left for a later recovery');
  assert.equal(k.claimCursor.get(VAULT), 3n, 'everything delivered, the cursor moves past it');
}));

test('a failed delivery is retried from the same request', () => delivering(true, async () => {
  const requests = [{ active: true, settled: 5n, surplus: 0n }, { active: true, settled: 5n, surplus: 0n }];
  const { k } = keeper(requests);
  k.poke = async () => false;
  await k.deliver(VAULT);
  assert.equal(k.claimCursor.get(VAULT), 0n);
}));

test('by default settled collateral waits for its owner, surplus is still pushed', async () => {
  assert.equal(CONFIG.DELIVER_CLAIMS, false);
  const requests = [
    { active: true, settled: 5n, surplus: 10n ** 17n, debtShare: 9n, repaid: 9n },
    { active: true, settled: 7n, surplus: 0n, debtShare: 9n, repaid: 9n },
  ];
  const { k, calls } = keeper(requests);
  await k.deliver(VAULT);
  assert.deepEqual(calls, [[LEDGER, 'claimSurplus', [0n]]]);
  assert.equal(k.claimCursor.get(VAULT), 2n, 'unclaimed but repaid requests hold nothing back');
});

test('without delivery the scan waits on a debt slice still being repaid', async () => {
  const requests = [
    { active: true, settled: 5n, surplus: 0n, debtShare: 9n, repaid: 9n },
    { active: true, settled: 2n, surplus: 0n, debtShare: 9n, repaid: 4n },
    { active: true, settled: 0n, surplus: 0n, debtShare: 9n, repaid: 0n },
  ];
  const { k, calls } = keeper(requests);
  await k.deliver(VAULT);
  assert.deepEqual(calls, []);
  assert.equal(k.claimCursor.get(VAULT), 1n);
});
