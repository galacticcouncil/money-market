import { toEventSelector } from 'viem';

export type FeedSeen = { answer: bigint; updatedAt: bigint; at: bigint };

// an answer that moved without a newer updatedAt (a composite feed) counts from when it was seen
export function feedUpdate(prior: FeedSeen | undefined, answer: bigint, updatedAt: bigint, now: bigint): FeedSeen {
  if (!prior || updatedAt > prior.updatedAt) return { answer, updatedAt, at: updatedAt };
  return { answer, updatedAt, at: answer === prior.answer ? prior.at : now };
}

// a sync in the same second as the update may precede it, so it does not count
export function syncDue(lastSync: bigint, lastUpdate: bigint | undefined, now: bigint, every: bigint): boolean {
  return (lastUpdate !== undefined && lastSync <= lastUpdate) || now - lastSync >= every;
}

// the yield accounting emits it whenever allocation runs: deposit, requestRedeem, startUnwinds, rebalance and sync
export const SYNC_EVIDENCE = [toEventSelector('Allocated()')];
