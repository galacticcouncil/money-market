const RAY = 10n ** 27n;

// aave counts the loop's HOLLAR debt as its scaled balance at the reserve index (rayMul, half up); the debt
// token's live balance already nets the discount. the difference is what a settlement would burn
export function pendingDiscount(scaledDebt: bigint, index: bigint, balance: bigint): bigint {
  const gross = (scaledDebt * index + RAY / 2n) / RAY;
  return gross > balance ? gross - balance : 0n;
}

// due at minBps of the loop's principal, never below the floor; zero bps turns settling off
export function discountDue(pending: bigint, principal: bigint, minBps: bigint, floor: bigint): boolean {
  if (minBps === 0n || pending === 0n || pending < floor) return false;
  return pending * 10_000n >= principal * minBps;
}
