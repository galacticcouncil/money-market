// backing = equityOf·1e10 − sourceValue; the shortfall is the larger of the debt left after active
// funds and the fee-grossed-up requirement, in bps of the debt, rounded up
export function vaultDeficitBps(debt: bigint, equityUsd8: bigint, sourceValue: bigint, activeFunds: bigint,
  required: bigint): bigint {
  if (debt <= 0n) return 0n;
  const backing = equityUsd8 * 10n ** 10n - sourceValue;
  const uncovered = debt - backing - activeFunds, unbacked = required - backing;
  const shortfall = uncovered > unbacked ? uncovered : unbacked;
  return shortfall <= 0n ? 0n : (shortfall * 10_000n + debt - 1n) / debt;
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
