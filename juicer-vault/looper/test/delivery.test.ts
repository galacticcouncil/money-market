import assert from 'node:assert/strict';
import { test } from 'node:test';
import { JuicerLooper } from '../src/looper.js';

const VAULT = '0x0000000000000000000000000000000000000002';
const LEDGER = '0x0000000000000000000000000000000000000003';
const OWNER = '0x00000000000000000000000000000000000000aa';

function keeper(requests: Array<{ active: boolean; settled: bigint; surplus: bigint }>) {
  const calls: Array<[string, string, unknown[]]> = [];
  const k = Object.create(JuicerLooper.prototype) as any;
  k.read = async (_abi: unknown, address: string, fn: string, args: bigint[] = []) => {
    if (fn === 'queueHead') return BigInt(requests.length);
    if (fn === 'mainDebt') return LEDGER;
    const r = requests[Number(args[0])];
    if (fn === 'redemptions') return [OWNER, 0n, 0n, 0n, 0n, 0n, r.settled, 0n, r.active];
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

test('settled claims and exit surplus are pushed to their owners', async () => {
  const requests = [
    { active: false, settled: 0n, surplus: 0n },
    { active: true, settled: 5n, surplus: 10n ** 17n },
    { active: true, settled: 7n, surplus: 1n },
  ];
  const { k, calls } = keeper(requests);
  await k.deliver(VAULT);
  assert.deepEqual(calls, [
    [VAULT, 'claim', [1n, OWNER]],
    [LEDGER, 'claimSurplus', [1n]],
    [VAULT, 'claim', [2n, OWNER]],
  ], 'dust surplus below the minimum is left for a later recovery');
  assert.equal(k.claimCursor.get(VAULT), 3n, 'everything delivered, the cursor moves past it');
});

test('a failed delivery is retried from the same request', async () => {
  const requests = [{ active: true, settled: 5n, surplus: 0n }, { active: true, settled: 5n, surplus: 0n }];
  const { k } = keeper(requests);
  k.poke = async () => false;
  await k.deliver(VAULT);
  assert.equal(k.claimCursor.get(VAULT), 0n);
});
