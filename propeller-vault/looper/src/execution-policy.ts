import { parseAbi, type Hex } from 'viem';

export const EXECUTION_ABI = parseAbi([
  'function preview(address target, bytes data) returns (bytes result, (bytes32 lane, uint256 amountIn, uint256 amountOut)[] fills)',
  'function previewBounded(address target, bytes data, (bytes32 lane, uint256 amountIn, uint256 minOut)[] caps) returns (bytes result, (bytes32 lane, uint256 amountIn, uint256 amountOut)[] fills)',
  'function available(address consumer, address tokenIn, address tokenOut) view returns (uint256)',
  'function lane(address consumer, address tokenIn, address tokenOut) pure returns (bytes32)',
  'function execute(address target, bytes data, uint256 quotedBlock, bytes32 quotedHash, uint256 deadline, (bytes32 lane, uint256 amountIn, uint256 minOut)[] quotes) returns (bytes result)',
]);

export type Fill = { lane: Hex; amountIn: bigint; amountOut: bigint };

export function executionQuotes(fills: readonly Fill[], driftBps: bigint, servicingLanes: ReadonlySet<string> = new Set()) {
  if (driftBps < 0n || driftBps >= 10_000n) throw new Error('invalid quote drift');
  const unique = new Map<Hex, {lane: Hex; amountIn: bigint; minOut: bigint}>();
  for (const f of fills) {
    if (f.amountIn <= 0n || f.amountOut <= 0n || unique.has(f.lane)) {
      throw new Error('missing output or repeated quote lane; split the batch');
    }
    const minOut = f.amountOut * (10_000n - driftBps) / 10_000n;
    if (minOut === 0n) throw new Error('quote rounds to zero');
    // Interest can grow between the pinned preview and inclusion. Permit extra
    // servicing input at the same unit price floor. Primary buy/harvest amounts
    // retain their exact preview caps, including adaptive reductions.
    const factor = servicingLanes.has(f.lane.toLowerCase()) ? 2n : 1n;
    unique.set(f.lane, {lane: f.lane, amountIn: f.amountIn * factor, minOut: minOut * factor});
  }
  return [...unique.values()];
}

// All monetary values use USD8. This is the fraction of realized gross yield
// spent on gas, not a prediction that the trade's full notional is profit.
export function worthwhileHarvest(value: bigint, gasCost: bigint, minimum: bigint, maxGasBps: bigint,
  urgent: boolean, age: bigint, maxDelay: bigint): boolean {
  if (value <= 0n) return false;
  if (urgent || age >= maxDelay) return true;
  return value >= minimum && gasCost * 10_000n <= value * maxGasBps;
}

export function operatorTurn(timestamp: bigint, slotSeconds: number, count: number, index: number): boolean {
  return Number(timestamp / BigInt(slotSeconds) % BigInt(count)) === index;
}
