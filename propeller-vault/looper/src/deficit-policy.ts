// active Main debt not covered by equityOf − sourceValue + activeFunds, in bps of the debt, rounded up
export function vaultDeficitBps(debt: bigint, equityUsd8: bigint, sourceValue: bigint, activeFunds: bigint): bigint {
  if (debt <= 0n) return 0n;
  const backing = equityUsd8 * 10n ** 10n - sourceValue + activeFunds;
  if (backing >= debt) return 0n;
  const shortfall = debt - (backing > 0n ? backing : 0n);
  return (shortfall * 10_000n + debt - 1n) / debt;
}

// above stop stops, below resume resumes; the band in between keeps the current flag
export function deficitStopped(bps: bigint, stopped: boolean, stop: bigint, resume: bigint): boolean {
  if (bps > stop) return true;
  if (bps < resume) return false;
  return stopped;
}

// a partial view can still prove a stop, never a resume
export function deficitLevel(parts: readonly (bigint | undefined)[], stop: bigint): bigint | undefined {
  const known = parts.filter((p): p is bigint => p !== undefined);
  const worst = known.reduce((a, b) => (b > a ? b : a), 0n);
  return worst > stop || known.length === parts.length ? worst : undefined;
}
