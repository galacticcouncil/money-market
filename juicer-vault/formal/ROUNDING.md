# funded-share transfer rounding

reviewed against `juicer-next` at `21f5aa7`, 10 october 2026. this is an implementation finding;
the Solidity contracts have not been changed by this formal work. the stacked allowance fix is
tracked separately in PR #73.

## bound

for funded vault shares `F`, total reward units `T > 0`, sender units `U`, and a requested
funded transfer `s`, the contract computes:

```
S = floor(F * U / T)
x = min(U, ceil(U * s / S))
D = S - floor(F * (U - x) / T)
G = floor(F * (V + x) / T) - floor(F * V / T)
```

`V` is the recipient's previous units, with `V + x <= T` so its unit cap is inactive.
sender and recipient are distinct ordinary holders;
self-transfers restore the same account's units and have zero net balance movement. successful positive transfers require `0 < s <= S`.
`take_exact_units` proves the cap is redundant on that domain. the Lean proofs
`take_displayed_bound`, `transfer_credit_refines`, and `transfer_discrepancy_at_most_one` establish:

```
floor(F * x / T) <= D, G <= ceil(F * x / T)
abs(D - G) <= 1
```

these are bounds on the sender's displayed debit and recipient's displayed credit, in vault
share base units. they are not one-wei bounds on `D - s` or `G - s`. the same unit transfer
also carries its pending source claim. `unit_granularity_unbounded` proves that with `T = U = 1`,
a request for one funded share moves the whole funded slice for any positive `F`. that theorem
alone does not establish that every such state is reachable in production.

there is no enforced constant funded-value-per-unit ratio: wallet shares can be donated to the
accounting contract without issuing reward units. the exact state-dependent bound above applies
under the stated cap condition, regardless of how a successful state was reached. no small global
production bound is claimed.

## public-call reproduction

`test_publicDonationMakesTransferRoundingExceedAllowance` uses the actual vault, accounting,
SubLoop, and harvester fixtures, with mocked external tokens/pool. it creates a small allocation,
transfers the wallet to a second actor, and that actor donates those wallet shares to the fund.
there are no storage writes or impersonated vault calls in this reproduction. external balance
minting represents the fixture's source income and repayment funding; it is not a live-chain test.

the original holder then approves one share base unit and the spender calls `transferFrom(..., 1)`:

| quantity | observed base units |
| --- | ---: |
| allowance consumed | 1 |
| sender displayed debit | 1,074,114 |
| recipient displayed credit | 1,074,113 |
| ceil(funded shares / total reward units) | 1,074,114 |

this establishes a reachable allowance/displayed-balance mismatch in the integration fixture.
the absolute movement in this example is small for an 18-decimal share. it does not establish
an economically profitable exploit, a maximum production loss, or deployed-state exposure.
512 additional fuzz cases check the proved display bounds against the actual accounting contract;
those cases seed arithmetic states and are not separate reachability evidence.

## disposition

exact-amount ERC20 behavior and allowance protection need an implementation decision. rounding a
unit count alone cannot guarantee exact displayed transfers when one unit represents multiple
share base units. a fix must either support exact funded-share accounting or explicitly reject
unrepresentable transfers; it must also preserve the pending source claim. merely charging the
requested allowance while moving more displayed balance does not resolve the finding.

reproduce with:

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

this is a seeded arithmetic counterexample, not a production loss estimate. the excess is one
**reward unit**, not one vault share. it invalidates an exact aggregate unit-conservation claim
across every lazy rescale; displayed funded claims also depend on the fund's shares-per-unit ratio.
it is separate from the allowance mismatch above.

`test_positiveResidualLossRefillsReachRescale` now shows that a rescale itself is public-call
reachable in the controlled vault/SubLoop fixture. it repeatedly leaves positive residual assets,
then restores source value and calls `sync`; after four cycles `unitScale` reaches 64 without an
epoch write-off. the fixture controls the external aPRIME balance by minting and burning mock
tokens. it does not write accounting storage and does not establish that the required value swings
are economically reachable against a deployed market.

`test_multiplePublicHoldersStayWithinTotalAtReachableRescale` repeats that path with three public
depositors. after the rescale their aggregate unit claims are two units below `totalUnits`; the
seeded one-unit excess is not reproduced by this public history. this separates two conclusions:
public calls can reach the rescale control flow, while the known excess state remains a seeded
arithmetic witness rather than a public-call reproduction.

`RescaleBounds.lean` proves the tighter one-step slack recurrence

```
E' <= ((T mod 2^k) * R + E) / 2^k + W
```

and a uniform arbitrary-history bound `E <= 2 * (R + cap)` when every rescale has positive shift
and tracked weight at most `cap`. it derives funded-claim bounds from that slack and proves no
aggregate funded overclaim when the resulting grain is smaller than `totalUnits`. these theorems
bound the seeded phenomenon; they do not turn the controlled reachability test into a deployed
economic path.
