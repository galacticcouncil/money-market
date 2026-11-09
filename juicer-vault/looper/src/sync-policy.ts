import { toEventSelector } from 'viem';

export type FeedSeen = { answer: bigint; updatedAt: bigint; at: bigint };

// an answer that moved without a newer updatedAt (a composite feed) counts from when it was seen
export function feedUpdate(
  prior: FeedSeen | undefined, answer: bigint, updatedAt: bigint, now: bigint, minChangeBps = 0n,
): FeedSeen {
  if (!prior || updatedAt > prior.updatedAt) return { answer, updatedAt, at: updatedAt };
  const change = answer > prior.answer ? answer - prior.answer : prior.answer - answer;
  const magnitude = prior.answer < 0n ? -prior.answer : prior.answer;
  // retain the reference price so small moves accumulate instead of resetting each poll
  if (change === 0n || change * 10_000n < magnitude * minChangeBps) return prior;
  return { answer, updatedAt, at: now };
}

// a sync in the same second as the update may precede it, so it does not count
export function syncDue(
  lastSync: bigint, lastUpdate: bigint | undefined, now: bigint, every: bigint, minInterval = 0n,
): boolean {
  if (lastSync > 0n && now - lastSync < minInterval) return false;
  return (lastUpdate !== undefined && lastSync <= lastUpdate) || now - lastSync >= every;
}

// the yield accounting emits it whenever allocation runs: deposit, requestRedeem, startUnwinds, rebalance and sync
export const SYNC_EVIDENCE = [toEventSelector('Allocated()')];
