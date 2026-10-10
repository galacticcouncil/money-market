# funded-share transfer rounding

this fixes the allowance mismatch found at `juicer-next` commit `ddf8186`. the implementation
and executable Lean model now require the sender's displayed funded debit to equal the request.
the result is reviewed on the allowance-fixed branch based on `juicer-next` at `21f5aa7`,
10 october 2026.

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

## lazy-rescale index correction

`LeanLazyHistoryParityTest` originally exposed a seeded arithmetic counterexample in the
accounting contract. before allocation, `totalUnits = 2^64 + 1`, `rewardIndex = 2^64`, an old
zero-weight holder stores `2^64 - 1` units, and two `RAY`-weight holders have prior index
`2^64 - 1`. an allocation performs one 64-bit rescale. shifting each prior index down with floor
division re-credited fractions that the global shift had discarded, so aggregate `balanceOf`
was `totalUnits + 1`.

the correction shifts a nonzero prior index upward:

```
ceilShift(p, k) = p == 0 ? 0 : ((p - 1) >> k) + 1
previous = min(shiftedRewardIndex, ceilShift(p, k))
```

`balanceOf` applies this to account indices and `startExit` applies it to waiting-request indices.
the formula avoids `1 << k`, so it remains defined when cumulative lazy shift is 256 or larger.
the `min` handles the case where the upward-rounded prior index is above the floor-shifted global
index. stored units and committed request units continue to shift downward.

an account-only candidate was incomplete in two ways. leaving `requestIndex` floor-shifted retained
the same extra pending unit when a waiting request crossed a rescale and later started. computing
`Math.ceilDiv(index, 1 << shift)` also made the divisor zero at `shift >= 256`, reverting a nonzero
stale account view. `RescaleCeilIndexAudit.t.sol` has seeded and public controlled regressions for
both paths.

### executable evidence

- `test_rescaleCeilIndexPreventsLazyUnitExcess` reruns the original seeded account case. the
  aggregate finishes at `totalUnits - 1`, remains bounded after settlement, and matches
  `runtime_rescale_ceil_index_closes_excess` in Lean.
- the rescale suites cover concentrated weight, a later allocation, account splitting and 256
  seeded fuzz cases. every corrected aggregate is at most `totalUnits`.
- `test_ceilShiftCoversAccountsAndWaitingRequests` combines an old holder, an active holder and a
  waiting request. their post-rescale claims equal `totalUnits`, and `startExit` preserves the
  bound.
- `test_fourShiftAllocationKeepsCeilShiftDefined` performs four 64-bit shifts in one allocation.
  a nonzero stale index remains readable at `unitScale == 256`.
- `test_publicControlledCyclesKeepCeilShiftDefined` reaches `unitScale == 256` after 12 controlled
  loss/refill cycles through public `sync` calls. `balanceOf` remains defined.
- `test_publicWaitingRequestUsesCeilShift` creates a real deposit and waiting redemption, reaches
  `unitScale == 64`, and checks that public `startUnwinds` burns the ceil-shifted request claim.

these public controlled tests use the actual vault, SubLoop and accounting entry points without
accounting storage writes or vault impersonation. the waiting-request trace raises the test TVL cap,
uses two deposits of `RAY` base units, and both public traces mint or burn mock aPRIME to represent
large external source-value changes. they establish control-flow reachability in the fixture, not
the economic feasibility of producing those conditions in a deployed market.

broader public searches in `RescaleReachability.t.sol` cover deposits, `rebalance`, `pokeBorrow`,
loss/refill cycles, transfers and account splitting. the untargeted 24-round and 60-round searches
remain at scale zero because zero-value losses take the write-off branch. the targeted
positive-residual fixture reaches scale 64 in four cycles; three public holders finish two units
below `totalUnits`.

`RescaleEconomics.t.sol` reruns the original seeded state at funded ratios of one and three shares
per unit. corrected aggregate displays remain within the fund, full displayed transfers remain
representable, and two exits satisfy `foldedFirst + foldedSecond + residue = F`. these tests show
how the correction behaves at the previously measured boundary; they do not estimate attacker
profit or deployed-market loss.

ceil-shifting deliberately resolves the ambiguous fractional boundary downward. the original
seeded state therefore finishes one reward unit below `totalUnits`; at funded ratios one and three,
the measured displayed headroom is one and three vault-share base units. exits conserve assets but
can leave the corresponding funded residue behind the unclaimed unit. exact redistribution of
every holder's discarded fraction would require aggregate holder state that this constant-cost
lazy design does not maintain. the no-overclaim theorem is an upper bound; it does not prove exact
aggregate conservation, a lower bound on claims, or a cumulative fairness bound for arbitrary
holder counts and repeated rescales.

### proof boundary

for current index `I`, prior index `p`, divisor `d = 2^k`, weight `w`, precision `R`, total units
`T` and numerator slack `E`, ceil-shifting gives:

```
d * (floor(I / d) - min(floor(I / d), ceil(p / d))) <= I - p
E' = floor(((T mod d) * R + E) / d)
```

`LazyOwnership.lean` proves the first inequality for each account and lifts it to aggregate
liability. the former `w * (d - 1)` rescale term disappears. `RescaleBounds.lean` proves that
`E < R` implies `E' < R`; ordinary steps preserve slack and write-off resets it. therefore any
modeled trace from genesis has aggregate unit claims at most `T`, including histories whose
liability slots represent waiting requests. for `T > 0`, the sum of individually floored funded
claims is also at most `F`.

`Rounding.lean` proves nested ceil shifts compose and proves the natural-number definition equals
the overflow-safe Solidity expression above, including shifts of 256 or more. `Runtime.lean`,
`Checked.lean` and their refinements use the corrected account and request semantics.

verdict. the original floor/floor arithmetic finding was real. the complete correction is a
constant-cost change with no holder scan: ceil-shift both ordinary and waiting-request indices with
the overflow-safe formula, then clamp to the current index. executable regressions close the known
seeded and controlled public traces, and the Lean model proves aggregate no-overclaim for its full
lazy-ledger transition system. economic reachability against a deployed market and full Solidity
trace equivalence remain outside these results.
