import { decodeEventLog, parseAbi, type Address } from 'viem';
import type { EvmLog, Hop } from './substrate.js';

export const ENTRY = 1; // HOLLAR → aPRIME
export const EXIT = 2; // aPRIME → HOLLAR
export const WAITING = 1;
export const FILLED = 2;
export const RETURNED = 3;

const SUBMITTED = parseAbi([
  'event IntentSubmitted(uint8 indexed kind, uint64 indexed nonce, uint256 amountIn, uint256 minOut, uint64 deadline)',
]);

export type Submitted = { kind: number; nonce: bigint; amountIn: bigint; minOut: bigint; deadline: bigint };

// keeperQuote: output units per 1e18 input units of the dry-run fill
export function quoteRate(amountIn: bigint, amountOut: bigint): bigint {
  if (amountIn <= 0n || amountOut <= 0n) throw new Error('empty router dry run');
  return amountOut * 10n ** 18n / amountIn;
}

// the intent a dry run of the loop's call would submit
export function submittedIntent(logs: readonly EvmLog[], loop: Address): Submitted | undefined {
  for (const log of logs) {
    if (log.address.toLowerCase() !== loop.toLowerCase()) continue;
    try {
      const { args } = decodeEventLog({ abi: SUBMITTED, topics: log.topics as any, data: log.data });
      return { ...args, kind: Number(args.kind) };
    } catch { /* another event of the loop */ }
  }
  return undefined;
}

// the loop's own router legs: HOLLAR →stableswap→ PRIME →aave→ aPRIME, and back
export function intentRoute(kind: number, ids: { hollar: number; prime: number; aPrime: number; pool: number }): Hop[] {
  const swap = (assetIn: number, assetOut: number): Hop => ({ pool: { Stableswap: ids.pool }, assetIn, assetOut });
  const aave = (assetIn: number, assetOut: number): Hop => ({ pool: 'Aave', assetIn, assetOut });
  return kind === ENTRY
    ? [swap(ids.hollar, ids.prime), aave(ids.prime, ids.aPrime)]
    : [aave(ids.aPrime, ids.prime), swap(ids.prime, ids.hollar)];
}

// one intent in flight per loop, so its pallet id is the owner's only one; an amount match breaks a tie
export function palletIntentId(intents: readonly { id: bigint; amountIn: bigint }[], amountIn: bigint): bigint | undefined {
  if (intents.length === 1) return intents[0].id;
  const matches = intents.filter(i => i.amountIn === amountIn);
  return matches.length === 1 ? matches[0].id : undefined;
}
