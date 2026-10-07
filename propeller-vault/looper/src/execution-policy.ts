import { parseAbi, type Hex } from 'viem';

export const EXECUTION_ABI = parseAbi([
  'function preview(address target, bytes data) returns (bytes result, (bytes32 lane, uint256 amountIn, uint256 amountOut)[] fills)',
  'function previewBounded(address target, bytes data, (bytes32 lane, uint256 amountIn, uint256 minOut)[] caps) returns (bytes result, (bytes32 lane, uint256 amountIn, uint256 amountOut)[] fills)',
  'function available(address consumer, address tokenIn, address tokenOut) view returns (uint256)',
  'function availableSafety(address consumer, address tokenIn, address tokenOut) view returns (uint256)',
  'function limits(bytes32 lane) view returns (bytes32 group, uint128 minimum, uint128 maximum)',
  'function lane(address consumer, address tokenIn, address tokenOut) pure returns (bytes32)',
  'function maxQuoteBlocks() view returns (uint64)',
  'function execute(address target, bytes data, uint256 quotedBlock, bytes32 quotedHash, uint256 deadline, (bytes32 lane, uint256 amountIn, uint256 minOut)[] quotes) returns (bytes result)',
]);

export type Fill = { lane: Hex; amountIn: bigint; amountOut: bigint };

// largest slice within tolerance of each lane's best sampled price; picks size only, never a floor
export function efficientCandidate<T extends {fills: readonly Fill[]}>(
  candidates: readonly T[], primary: ReadonlySet<string>, toleranceBps: bigint,
): T {
  if (!candidates.length || toleranceBps < 0n || toleranceBps >= 10000n) throw new Error('invalid sizing candidates');
  const best = new Map<string, Fill>();
  const required = new Set<string>();
  for (const candidate of candidates) {
    const seen = new Set<string>();
    for (const fill of candidate.fills) {
      const key = fill.lane.toLowerCase();
      if (fill.amountIn <= 0n || fill.amountOut <= 0n || seen.has(key)) throw new Error('invalid sizing fill');
      seen.add(key);
      if (primary.has(key)) required.add(key);
      const prior = best.get(key);
      if (!prior || fill.amountOut * prior.amountIn > prior.amountOut * fill.amountIn) best.set(key, fill);
    }
  }
  const ranked = candidates.map(candidate => {
    const present = new Set(candidate.fills.map(f => f.lane.toLowerCase()));
    let gap = 0n, volume = 0n;
    for (const fill of candidate.fills) {
      const key = fill.lane.toLowerCase(), optimal = best.get(key)!;
      const denominator = optimal.amountOut * fill.amountIn;
      const loss = denominator - fill.amountOut * optimal.amountIn;
      const bps = (loss * 10000n + denominator - 1n) / denominator;
      if (bps > gap) gap = bps;
      // primary lanes in one action share an input token (HOLLAR or PRIME)
      if (primary.has(key)) volume += fill.amountIn;
    }
    return {candidate, gap, volume, complete: [...required].every(key => present.has(key))};
  }).filter(c => c.complete && c.volume > 0n);
  if (!ranked.length) throw new Error('no complete sizing candidate');
  const close = ranked.filter(c => c.gap <= toleranceBps);
  const choices = close.length ? close : ranked;
  choices.sort((a, b) => {
    if (!close.length && a.gap !== b.gap) return a.gap < b.gap ? -1 : 1;
    return a.volume === b.volume ? 0 : a.volume > b.volume ? -1 : 1;
  });
  return choices[0].candidate;
}

export function executionQuotes(fills: readonly Fill[], driftBps: bigint, servicingLanes: ReadonlySet<string> = new Set()) {
  if (driftBps < 0n || driftBps >= 10_000n) throw new Error('invalid quote drift');
  const unique = new Map<Hex, {lane: Hex; amountIn: bigint; minOut: bigint}>();
  for (const f of fills) {
    if (f.amountIn <= 0n || f.amountOut <= 0n || unique.has(f.lane)) {
      throw new Error('missing output or repeated quote lane; split the batch');
    }
    const minOut = f.amountOut * (10_000n - driftBps) / 10_000n;
    if (minOut === 0n) throw new Error('quote rounds to zero');
    // interest can grow before inclusion: servicing gets 2x input at the same unit floor, primary caps stay exact
    const factor = servicingLanes.has(f.lane.toLowerCase()) ? 2n : 1n;
    unique.set(f.lane, {lane: f.lane, amountIn: f.amountIn * factor, minOut: minOut * factor});
  }
  return [...unique.values()];
}

// values in USD8; maxGasBps bounds gas against realized yield, not trade notional
export function worthwhileHarvest(value: bigint, gasCost: bigint, minimum: bigint, maxGasBps: bigint,
  urgent: boolean, age: bigint, maxDelay: bigint): boolean {
  if (value <= 0n) return false;
  if (urgent || age >= maxDelay) return true;
  return value >= minimum && gasCost * 10_000n <= value * maxGasBps;
}

export function operatorTurn(timestamp: bigint, slotSeconds: number, count: number, index: number): boolean {
  return Number(timestamp / BigInt(slotSeconds) % BigInt(count)) === index;
}
