# CheckedOracle — write-time deviation check on a ManagedOracle

`contracts/CheckedOracle.sol` extends `ManagedOracle` with a sanity check on the
*write* path: a pushed price is rejected unless it sits within `maxDiffBps` of a
check feed — Hydration's on-chain EMA oracle precompile for the asset's pool.

## Why write-time and not read-time

`ClampedOracle` (see `prime-oracle-clamped.md`) wraps a feed and clamps it into a
band on every read. `CheckedOracle` instead validates once, when the price is
pushed, and stores only prices that passed.

| | ClampedOracle | CheckedOracle |
|---|---|---|
| Where the band applies | every read | the `setPrice` call |
| Reported price | primary, possibly clamped to a band edge | exactly what was pushed |
| Bad push | silently clamped, keeps being clamped | reverts; pusher sees the error and retries |
| Read cost | 2 external calls per read | plain storage load |
| Stale check feed | reported price drifts with the EMA | last accepted price stays put |
| Ownership of the source | wraps someone else's feed | *is* the feed |

CheckedOracle is the right shape where we own the feed (the `ManagedOracle`s
pushed by the whm relay / MRL) and want the pushed value bounded. ClampedOracle
is the right shape where we can't change the source at all. They compose: a
ClampedOracle can take a CheckedOracle as its primary.

## Roles

- **`pusher`** — pushes prices via `setPrice`. Every push is checked. A
  compromised pusher key can only move the reported price inside
  ±`maxDiffBps` of the pool EMA, at the EMA's own speed.
- **`owner`** (governance) — sets `checkOracle`, `maxDiffBps` and `pusher`, and
  can push unchecked via `setPriceUnchecked`. Fully trusted, exactly as the
  owner of a plain `ManagedOracle` is today.

Setting `pusher` to `address(0)` disables relayed pushes; the owner can still
push (checked or unchecked).

## Semantics

- Accept iff `|price − check| · 10000 ≤ maxDiffBps · check`, cross-multiplied,
  so the band edges are exact and inclusive on both sides.
- `price <= 0` → `InvalidPrice`.
- **Fail closed:** check feed reverts, returns `<= 0`, or is unset →
  `CheckPriceUnavailable`, the update is rejected and the last accepted price
  stands. Recovery paths: the feed comes back, governance swaps the feed, or
  the owner pushes unchecked.
- The check feed's answer is rescaled to the oracle's 8 decimals using its
  `decimals()`, read once when the feed is set. A feed that doesn't answer
  `decimals()` is assumed to be 8 (the precompile convention) and that
  assumption is emitted in `CheckOracleUpdated`; more than 36 decimals is
  rejected as `InvalidFeed`.
- **The constructor price is not checked.** Deploying is an owner action of the
  same weight as `setPriceUnchecked`, and checking it would make the oracle
  undeployable exactly when the managed price legitimately sits outside the band
  (e.g. apyUSD's fixed $1.3672 against a depegged pool). `deploy-checked-oracle`
  prints the deviation at deploy time so the gap is visible, not silent.

Pre-flight for the relayer, so a push is never sent blind:

```solidity
(bool ok, uint256 deviationBps) = oracle.previewSetPrice(price);
(bool feedOk, int256 checkPrice) = oracle.checkPrice(); // normalised to 8 dec
```

## Picking the check feed and the band

The check feed is the pool EMA precompile for the asset's pair; byte 3 of the
precompile address selects the EMA period (10-min / hour / day / week). Longer
period = harder to manipulate, slower to let a real move through. See the
apyUSD study for the trade-off (day EMA = 8.3 h half-life).

Band width is the cap on damage from a bad push. It has to be wide enough to
cover the *legitimate* standing gap between the managed price and the pool — for
an asset whose pool trades persistently below fair value, a tight band around
the pool EMA will reject every honest push. Measure the historical spread first;
size the band over its observed range, as with PRIME's ±200 bps (worst observed
divergence −0.47% / +1.25%).

## Deployment

```
npx hardhat deploy-checked-oracle \
  --name APYUSD \
  --description "APYUSD/USD" \
  --owner <governance> \
  --price <8-decimal price> \
  --check <ema precompile> \
  --max-diff-bps 200 \
  --pusher <relayer> \
  --network hydration
```

Swapping an existing `ManagedOracle` for a `CheckedOracle` is an
`AaveOracle.setAssetSources` call through governance, same as any other source
swap.

## Tests

`tests/foundry/CheckedOracle.t.sol` — 42 tests incl. fuzz over
(check price, pushed price, band): acceptance matches the band exactly, the
reported price never leaves the band no matter what the pusher tries, and only
pusher/owner can move it.
