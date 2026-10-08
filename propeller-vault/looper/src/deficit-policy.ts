import { getAddress, keccak256, slice, toBytes, toEventSelector, zeroHash, type Address, type Hex } from 'viem';

export type DeficitState = 'ok' | 'stopped';

// active Main debt not covered by equityOf − sourceValue + activeFunds, in bps of the debt, rounded up
export function vaultDeficitBps(debt: bigint, equityUsd8: bigint, sourceValue: bigint, activeFunds: bigint): bigint {
  if (debt <= 0n) return 0n;
  const backing = equityUsd8 * 10n ** 10n - sourceValue + activeFunds;
  if (backing >= debt) return 0n;
  const shortfall = debt - (backing > 0n ? backing : 0n);
  return (shortfall * 10_000n + debt - 1n) / debt;
}

// above stop stops, below resume resumes; the band in between keeps the previous state
export function deficitState(bps: bigint, previous: DeficitState, stop: bigint, resume: bigint): DeficitState {
  if (bps > stop) return 'stopped';
  if (bps < resume) return 'ok';
  return previous;
}

// a partial view can still prove a stop, never a resume
export function deficitLevel(parts: readonly (bigint | undefined)[], stop: bigint): bigint | undefined {
  const known = parts.filter((p): p is bigint => p !== undefined);
  const worst = known.reduce((a, b) => (b > a ? b : a), 0n);
  return worst > stop || known.length === parts.length ? worst : undefined;
}

export const DEPOSIT_GUARDIAN_ROLE = keccak256(toBytes('DEPOSIT_GUARDIAN_ROLE'));
// holders of any of these are governance or guardians, never keepers
export const GOVERNANCE_ROLES = [zeroHash, ...['ADMIN_ROLE', 'GUARDIAN_ROLE', 'UPGRADER_ROLE'].map(r => keccak256(toBytes(r)))];

// both shapes are accepted: `()` like BILVault, or `(address account)` indexed or not
export const DEPOSITS_PAUSED = ['DepositsPaused()', 'DepositsPaused(address)'].map(e => toEventSelector(e));
export const DEPOSITS_UNPAUSED = ['DepositsUnpaused()', 'DepositsUnpaused(address)'].map(e => toEventSelector(e));

// the account named by the event, if it names one; otherwise the caller falls back to the transaction sender
export function eventAccount(log: {topics: readonly Hex[]; data: Hex}): Address | undefined {
  if (log.topics.length > 1) return getAddress(slice(log.topics[1], 12));
  if (log.data.length >= 66) return getAddress(slice(log.data, 12, 32));
  return undefined;
}
