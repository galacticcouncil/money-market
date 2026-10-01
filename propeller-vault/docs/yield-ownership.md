# Separate ownership of source yield

**2 October 2026 — design candidate for #62; ownership accounting is not implemented.**

The selected constraint is to preserve collateral-denominated claims. Deposits
continue to mint against actual collateral backing. Unrealized PRIME yield must
not increase the collateral share price or a fixed collateral withdrawal promise.
This revision removes #62's proposed pending-carry deposit premium. It keeps the
independent protection that only the configured Harvester can pull source yield,
inside the same transaction that distributes it.

The remaining deposit-before-harvest capture finding is still open. Neither the
atomic-call restriction nor the model below fixes it in the production contracts.
Keep #62 in draft and keep the release activation gate open until the ownership
implementation and its integration tests exist.

## Why deposit NAV pricing was rejected

With one collateral token backing one incumbent share, 0.1 tokens of unrealized
yield, and a new one-token deposit, the proposed denominator mints `1 / 1.1`
shares. Before harvest the entrant's collateral conversion is only `20 / 21`,
about **0.952381 tokens**. The missing 0.047619 is an interest in unrealized source
yield, not funded collateral. Later source recovery is not proof that the original
deposit can be returned in the same asset. These are illustrative unit prices,
not a native-chain withdrawal simulation.

Adding that source NAV to withdrawal promises would require another conversion
and funding mechanism and would change the product's accounting promise. Merely
subtracting Main interest or a fee from the pending-carry quote does not resolve
the distinction between an owned source asset and a funded collateral claim.

## Proposed accounting boundary

Keep two independently conserved ownership systems:

| Record | Meaning | Entry and realization rule |
| --- | --- | --- |
| Collateral shares | Existing collateral backing and settled collateral claims | Mint against actual collateral, as today. Never include unrealized source earnings. |
| Source ownership units | A cohort's funded claim on source equity, including retained earnings | New seed buys units at pre-entry source NAV. It does not buy another cohort's profit entitlement. |
| Main debt units/basis | Principal and indexed interest owned by that cohort | Allocate before entry, transfer or exit. Do not charge a newcomer for pre-entry Main interest. |
| Retained source yield | Earned units reserved for execution costs | Keep their owner recorded while they remain invested. Release or actual cost consumes the relevant owner's units. |
| Realized reward shares | Collateral already supplied from realized, after-fee, after-interest yield | Mint fully backed shares to a reward escrow and credit the beneficiary. Do not spread that reward through the exchange rate of all outstanding shares. |

The current source already prices vault deposits at NAV. The missing boundary is
inside each collateral vault: its holders are currently pooled into one earning
position. Introduce a per-vault ownership component rather than placing more
unbounded state/logic in CollateralVault, which has only 138 bytes of runtime
headroom after #61. Its records must reconcile to the vault's aggregate source
shares and #60's Main-debt ledger; they must not be a second set of independently
mintable claims on the same assets.

The model materializes a cohort directly. A deployable representation must use
lazy checkpoints and bounded batches, not iterate through every holder on deposit,
transfer or harvest. The final representation and gas bounds remain implementation
work; the model does not establish that an efficient representation already exists.

## Realization sequence

1. Checkpoint source ownership and indexed Main interest before entry, ownership
   movement, an unwind snapshot, or a harvest batch. Preserve #60's existing cash,
   cost and late-recovery reservations.
2. Select only the owning cohort's available yield, after its retained execution
   allowance. A partial harvest leaves the remainder invested and owned.
3. Remove source value and **burn/reduce only the matching ownership units** at
   pre-realization NAV. Withdrawing value while leaving every source unit intact
   would lower newcomers' backing even if the cash payout went to old holders.
   Existing `SubLoop.harvest` does not perform this accounting change yet.
4. Allocate actual route output and actual execution loss to the same owner.
   Apply the existing order: protocol fee, owned Main interest, then collateral
   reward. Insufficient fresh yield leaves interest outstanding; previously
   supplied collateral is not an interest-payment source.
5. Supply the remainder as collateral and mint matching funded reward shares.
   Crediting them through an escrow keeps realization bounded and leaves other
   holders' collateral exchange rate unchanged. Beneficiaries must be able to
   materialize their shares permissionlessly; escrow ownership must also be
   included in future earnings so a delayed claim does not lose compounding.

Transfers and exits require explicit checkpoint rules. Proposed policy: an
account retains separately accrued rewards; the receiving account starts a new
earning interval. The implementation must preserve the associated source units,
retained-yield rights and pre-transfer debt/interest obligations together. Simply
moving collateral shares or resetting the receiver's reward index is insufficient.
Prove this partition before enabling that path; no transfer behavior is changed
by this design PR.

At unwind start, move the exiting portion of all ownership records into the exit
cohort. Partial collateral claims must not close residual source/reward rights.
The original owner retains subsequent recoveries, as in #60. Deficits may delay
payment, but cannot erase the collateral claim or become another holder's debt.

## Quantified example and executable study

The [exact-rational study](../../scripts/propeller/yield-ownership-study.mjs)
uses unit collateral/HOLLAR prices and abstracts away leverage, Aave rounding,
liquidity, oracle changes, gas and storage representation. It demonstrates the
accounting boundary, not production execution or a promised APY.

An incumbent deposits 1 token, earns 0.1 source value, and accrues 0.02 Main
interest. A newcomer deposits 1 token. Retain 0.04 of the incumbent's yield and
realize 0.06 with a 5% fee:

| Result | Amount |
| --- | ---: |
| Fee on realized yield | 0.003 |
| Main interest paid | 0.020 |
| Funded reward for incumbent | 0.037 |
| Incumbent collateral claim | 1.037 |
| Newcomer collateral claim | 1.000 |
| Incumbent's retained source yield | 0.040 |
| Newcomer's pre-entry yield entitlement | 0 |

Eight exact-arithmetic checks cover entry fairness, partial realization, retained
yield release, fee/interest ordering, realized execution loss, insufficient yield,
post-entry earnings and 100 partial harvests. Run from the repository root:

```sh
node --test-reporter=tap scripts/propeller/yield-ownership-study.test.mjs
node scripts/propeller/yield-ownership-study.mjs
```

## Conditions before #62 can become merge-ready

- Implement the ownership component and the required source-unit adjustments;
  reconcile all asset, unit, debt, cash and escrow totals across both layers.
- Prove deposit, transfer, multi-vault entry, delayed/partial harvest and exit
  permutations, including price changes and non-unit collateral prices.
- Test actual fees, Main discounts/interest, retained-yield cost consumption,
  loss/recovery, donations and configuration changes without cross-owner subsidy.
- Invert the earlier production-contract late-deposit characterization into a
  passing prevention regression, and follow withdrawals through their final
  collateral and source/reward claims.
- Bound storage growth and gas for every public path; recheck bytecode sizes,
  storage layout, keeper work and fresh native execution.
- Expose funded reward claims separately from unrealized owned yield in the UI.
  Until this is implemented, #3978 exposes #60's Main-debt recoveries only.

This design is compatible with a shared execution budget and partial atomic
harvests. Those size/rate controls remain a separate implementation. The ledger
allows harvest scheduling to follow execution economics without making delayed
yield available to newcomers; it does not establish the optimal trading policy.
