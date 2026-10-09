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
