import type { Hex } from 'viem';

export type EvidenceLog = { block: bigint; index: number; topics: Hex[]; data: Hex; tx: Hex };
export type NewestLog = (from: bigint, to: bigint) => Promise<EvidenceLog | undefined>;

export const LOG_CHUNK_BLOCKS = 5000n;
// recent blocks are rescanned every lookup; a cached log that vanished from them was reorged out
export const REORG_MARGIN_BLOCKS = 32n;

// the newest log matching one filter, tracked across cycles
export class LatestLog {
  private scanned?: bigint;
  private last?: EvidenceLog;

  constructor(private readonly lookback: bigint) {}

  async find(newest: NewestLog, head: bigint): Promise<EvidenceLog | undefined> {
    if (this.scanned !== undefined && head >= this.scanned) {
      const from = this.scanned >= REORG_MARGIN_BLOCKS ? this.scanned - REORG_MARGIN_BLOCKS + 1n : 0n;
      const fresh = await newest(from, head);
      if (fresh || !this.last || this.last.block < from) {
        this.last = fresh ?? this.last;
        this.scanned = head;
        return this.last;
      }
    }
    // first lookup, a head that went backwards, or a reorged log: search back from the head once
    this.last = await newest(head >= this.lookback ? head - this.lookback + 1n : 0n, head);
    this.scanned = head;
    return this.last;
  }
}

// walks back from `to` in bounded chunks and stops at the first chunk with a match
export async function newestInChunks(
  getLogs: (from: bigint, to: bigint) => Promise<EvidenceLog[]>, from: bigint, to: bigint,
): Promise<EvidenceLog | undefined> {
  for (let hi = to; hi >= from; ) {
    const lo = hi - from + 1n > LOG_CHUNK_BLOCKS ? hi - LOG_CHUNK_BLOCKS + 1n : from;
    const logs = (await getLogs(lo, hi)).sort((a, b) => a.block === b.block ? a.index - b.index : a.block < b.block ? -1 : 1);
    if (logs.length) return logs[logs.length - 1];
    hi = lo - 1n;
  }
  return undefined;
}
