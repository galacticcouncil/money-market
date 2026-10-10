# funded-share transfer rounding

this fixes the allowance mismatch found at `juicer-next` commit `ddf8186`. the implementation
and executable Lean model now require the sender's displayed funded debit to equal the request.

## exact sender debit

for funded vault shares `F`, total reward units `T > 0`, sender units `U`, and a requested
funded transfer `s`, accounting computes:

```
S = floor(F * U / T)
R = ceil((S - s) * T / F)
x = min(U - R, ceil(U * s / S))
D = S - floor(F * (U - x) / T)
G = floor(F * (V + x) / T) - floor(F * V / T)
```

positive transfers require `0 < s <= S`. `R` is the minimum retained unit count that prevents
an excessive debit. the proportional candidate still limits the source claim that moves.
if the resulting sender balance is not exactly `S - s`, `_take` reverts `InexactShares`.
`transferFrom` and delegated `requestRedeem` share this guard, measured after account settlement
and any redemption checkpoint; a revert restores allowance,
wallet shares, reward units and queue state.

`take_displayed_exact` proves `D = s` for every successful modeled call.
`take_full_slice` proves a full funded exit takes all the owner's units.
`take_fine_available` proves every amount within the funded balance is representable when
`0 < F <= T`. `take_representable` also covers coarse units when the target remainder is
representable. `coarse_partial_rejected` proves a single coarse unit cannot be partially spent.
self-transfers validate the balance without moving units, so they remain no-ops even when an
ordinary transfer of that amount would be unrepresentable.

`V` is the recipient's previous settled units. when `V + x <= T` (the recipient's
`balanceOf` unit cap does not truncate the credit), the floor/ceiling proofs establish:

```
floor(F * x / T) <= D, G <= ceil(F * x / T)
D = s
abs(G - s) <= 1
```

exact sender debit does not imply exact recipient credit: under that unit bound, rounding the
recipient's separate unit balance can differ by one vault-share base unit. pending source ownership still travels
with the units, and third-party units and balances do not change. total reward units are
unchanged by a transfer. wallet-only transfers retain their existing behavior.

## donation regression

wallet shares can be donated to accounting without issuing units, so `F / T` has no enforced
constant upper bound. under the previous implementation, a public-call fixture with one
base-unit approval produced a sender debit of 1,074,114 and recipient credit of 1,074,113.
that example showed an allowance mismatch; it did not establish a profitable exploit or a
maximum production loss.

`LeanRoundingReachabilityTest` uses the actual vault, accounting, SubLoop and harvester fixtures
with mocked external tokens and pool. it creates a small allocation and donates wallet shares
to the fund without seeding accounting storage or impersonating the vault. eight regressions
check the rejected one-unit transfer and delegated redemption, direct transfer rejection,
representable partial transfer and redemption, full transfer, full unwind and self-transfer.
failed calls leave the approval and ownership intact.

512 arithmetic fuzz cases check exact sender debits, recipient bounds, representability and
unit conservation against the accounting contract at both fine and coarse unit ratios.
86 Lean-generated take vectors include full-precision mul-div inputs whose intermediate
products exceed 256 bits. these seeded arithmetic comparisons are separate from reachability
evidence and do not establish full Solidity equivalence.

```sh
forge test --offline --match-contract LeanRoundingReachabilityTest --match-test test_publicDonation -vv
```

## separate lazy-rescale limitation

`test_rescaleCanLeaveOneExcessLazyUnit` in `LeanLazyHistoryParity.t.sol` reproduces a different
rounding boundary in the actual accounting contract. the fixture seeds a valid aggregate unit
balance before allocation: total units are `2^64 + 1`, the current index is `2^64`, an old holder
owns `2^64 - 1` units with no wallet weight, and two holders each have wallet weight `RAY` and
previous index `2^64 - 1`. their two pending units complete the initial total.

an allocation with source shares `2`, source holdings/equity `2 * 10^38`, zero fee/backing/funded
shares and outside supply `2 * RAY` triggers one 64-bit rescale. the old holder's units round to
zero; the two previous indices also round to zero. the resulting sum of unit balances is
`totalUnits + 1`, including after both holders settle. `runtime_rescale_unit_excess` checks the
same initial state and executable allocation in Lean.

this is a seeded arithmetic counterexample, not a public-call reachability proof or a production
loss estimate. the excess is one **reward unit**, not one vault share. it invalidates an exact
aggregate unit-conservation claim across every lazy rescale; displayed funded claims also depend
on the fund's shares-per-unit ratio. it is separate from the allowance mismatch fixed above.

### candidate correction: ceil-shifted rescale indices (this branch)

this branch implements the smallest fix: `balanceOf` ceil-shifts a current-epoch account's
stored index (`Math.ceilDiv(accountIndex, 1 << shift)`, clamped at `rewardIndex`) instead of
floor-shifting it. the mechanism is the floor/ceil asymmetry: a rescale floors stored units
(`u >> shift`) but also floored the stored index, letting pending accrual `w * (I' - p')` re-claim
the floored fraction. ceil-shifting the index makes pending accrual only shrink, so the seeded
counterexample now yields `totalUnits - 1` (a one-unit under-claim) instead of `totalUnits + 1`.
the clamp at `rewardIndex` avoids an underflow for an account settled at a non-aligned index.

validated: the seeded parity fixture, the four `Rescale*` suites, the 826 Lean runtime vectors
and the full Foundry suite (59 suites) pass; bytecode is 12,615 bytes (+102), CollateralVault
unchanged at 24,480.

**deferred Lean realignment.** the executable Lean model (`Runtime.accountUnits`) and the lazy
trace invariant (`LazyOwnership`) still floor-shift the index, so they describe the pre-fix
semantics and the `runtime_rescale_unit_excess` counterexample is checked against the old model.
realigning them requires the strengthened rescale lemmas (`lazy_rescale_numerator` /
`lazy_rescale_liability` dropping the `+ weight * (d - 1)` term, and a nested
ceil/floor-of-power identity `ceil(⌊x/2^n⌋/2^k) = ceil(x/2^(n+k))`). those natural-number
division identities resisted `omega`/`nlinarith` automation in this environment and are left as
explicit follow-up: the Solidity change and its behavior are fully tested, but the Lean model
and proofs must be updated (and the vectors regenerated) before this branch is treated as the
new reviewed baseline.

### investigation of the rescale excess (item 1, october 2026)

mechanism. `_allocate` rescales by shifting `totalUnits` and `rewardIndex` down 64 bits when
`totalUnits > 2^160 * denominator / max(denominator, outsideValue)`. `balanceOf` shifts a
current-epoch account's stored units and index lazily. the rounding split is:

- stored units `u` become `floor(u / 2^64)`;
- pending accrual re-forms at the shifted indices as `w * (I' - floor(p / 2^64)) / RAY`,
  which overcounts the shifted entitlement `w * (I - p) / (RAY * 2^64)` by up to
  `w * (2^64 - 1) / (RAY * 2^64)` per account;
- the per-account `min(totalUnits, ...)` cap truncates any single holder's excess.

the seeded case is minimal for a non-trivial excess: one stale holder with wallet weight `RAY`
produces `floor((M + 2) / 2) * 2 = M + 2` against `totalUnits = M + 1`, and the old holder's
floored `2^64 - 1` stored units free exactly the headroom the cap would otherwise remove.

accumulation. empirical seeded-state runs in `RescaleAmplification.t.sol`:

- one rescale with two stale `RAY` holders leaves exactly one excess unit;
- concentrating all stale weight on one holder cannot push that holder past `totalUnits`
  (the per-account cap binds);
- a second allocation from the already-rescaled state leaves the excess at one: the rescale
  collapses the index range, so the same holders' subsequent pending accrual is floored to
  zero units until the index grows by another `RAY`-scaled step;
- a 256-case fuzz over seeded totals, indices and holder counts never produced an excess
  above the stale-holder count, and the aggregate never exceeded `3 * totalUnits + holders`
  (the per-account cap envelope).

public-call reachability. `RescaleReachability.t.sol` drives the deployed vault, SubLoop and
accounting through deposits, `rebalance`, `pokeBorrow`, loss/refill cycles on the mocked prime
position, wallet transfers and account splitting. across 24 deep loss/refill rounds and a
60-round approach test, `totalUnits` tracked roughly one third of `totalAssets` and
`unitScale` never left zero. reaching one rescale through public calls requires
`totalUnits > 2^160 * denominator / max(denominator, outsideValue)`; with
`totalUnits ~ before / 3` that needs a unit-to-asset ratio near `10^48`, i.e. the fund's asset
value must fall to about `2^112` times the total asset base without a write-off. losses alone
cannot do that: when the pre-allocation value reaches zero, `_allocate` writes the fund off
instead of rescaling. no public-call path was found, and the write-off/reset behavior is the
structural reason the seeded index `2^64` at totalUnits `2^64 + 1` cannot be grown by deposits
alone: index growth mints units at least proportionally to `outsideSupply / RAY`.

measured impact. `RescaleEconomics.t.sol` runs actual `settle`, transfer and `startExit` calls
on the post-rescale state:

- at one funded share per unit the excess displays one extra share (`floor(F/T) = 1`);
- under a 3x donation (coarse units) the aggregate display exceeds the fund by three shares,
  and a full-slice transfer of the excess still succeeds;
- exiting both holders folds `foldedFirst + foldedSecond + residue = F` exactly: the excess
  unit changes who receives the fund's shares, not how many shares exist;
- with concentrated wallet weight the per-account cap activates and reduces the aggregate
  excess instead of growing it.

verdict. the finding is a real arithmetic counterexample to exact aggregate unit conservation,
but it is not reachable through observed public-call sequences, the excess does not compound
across consecutive allocations without an intervening index-building phase, and its collateral
effect is bounded by `floor(F * excess / totalUnits)` — already covered by the proved
`lazy_funded_claims_bound`. no correction is proposed here: the smallest change that would
remove the one-unit excess (per-holder floor alignment at rescale) would add holder-scanning
state or break lazy constant-cost accounting, and the proved funded bound already caps the
asset-level effect below one share per unit of excess at any reachable `F/T`.
