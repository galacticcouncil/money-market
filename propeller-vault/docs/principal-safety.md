# Principal Preservation and Emergency Recovery

**Current RC1 policy | 23 September 2026**

Protect the user's original principal in the deposited asset. A 1 ETH deposit
is a token-denominated principal obligation, not a promise to preserve its USD
value. Preserving that claim does not guarantee immediate withdrawal or fund a
shortfall. Governance supplies recovery capital when required.

This document describes the policy, implemented controls and remaining limits.
The [RC checklist](release-candidate.md) governs production activation; the
[historical record](principal-safety-history.md) preserves earlier discussions
and dated test results.

## Protection Model

| Exposure         | Treatment                                                                                                                                                                  |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Main collateral  | Not sold for ordinary strategy-loss recovery or interest servicing. Synthetic collateral maintains a health-factor floor under valid configuration and timely maintenance. |
| PRIME strategy   | Can incur trading losses, negative carry or liquidation. Lost source value can leave HOLLAR shortfalls without reducing the recorded collateral claim.                     |
| Unpaid claims    | Remain outstanding when execution or funding is insufficient. No automatic haircut or write-off to finish an exit.                                                         |
| New deposits     | Blocked while the contract's backing checks report underfunding; new users are not a recovery fund.                                                                        |
| Yield            | Not guaranteed. Un-compounded earned yield can absorb eligible execution costs. Compounded yield may contribute to governance-approved emergency recovery.                 |
| Recovery funding | External governance responsibility. No dedicated automatic strategy-loss reserve or fixed repayment deadline is implemented.                                               |

Main's synthetic floor is not HOLLAR liquidity. Interest keeps accruing during
outages, and floor maintenance still needs functioning permissions, market
configuration and keeper execution. It is not accurate to describe Main as
unconditionally immune to liquidation for all future operating conditions.

Ordinary Main interest uses fresh after-fee harvests; collateral-value declines
are handled by shrinking the PRIME loop and repaying Main from its net HOLLAR.
See [Main debt servicing](main-debt-servicing.md) for debt ownership and funding.

## Withdrawal Delay

The default is **12 hours before an unwind may start**, configurable per vault
with `setWithdrawalDelay(uint32)`. Zero disables the delay for future requests.
Existing requests retain their recorded `unwindEligibleAt`.

1. `requestRedeem` escrows shares. They remain invested and share yield and debt
   during the wait; no source unwind is started for that request.
2. `startUnwinds(maxRequests)` starts eligible requests in FIFO order. It snapshots
   collateral owed and allocates Main debt and source claims at that point.
3. Source repayments and `pokeSettle` fund collateral release. Post-start
   interest belongs to that exit, not the remaining holders' cash.
4. `claim` pays settled collateral, including partial claims. Unpaid balances
   stay open; late source surplus remains owned by the original exit holder.

A shorter newly configured delay does not allow a request to jump an older
FIFO request. An elapsed delay does not bypass an emergency freeze. Twelve
hours is an incident-response window and minimum wait, not a settlement SLA;
it cannot reverse payouts completed before the pause.

## Pause Controls

| Control                   | User flows                                                                                            | Safety operations                                                               |
| ------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Vault `pause()`           | Stops local deposits, requests, starts, FIFO allocation, claims and share transfers.                  | Main repayment and `maintainPeg` remain callable.                               |
| Source `pauseEmergency()` | Freezes attached vaults and stops new source risk and ordinary unwind allocation.                     | Permits source safety deleveraging and Main maintenance.                        |
| Source `pause()`          | Stops source route execution, including ordinary borrowing/unwinding. It is not a vault claim freeze. | Also stops source safety swaps; use only when route execution itself must stop. |

Guardians can activate emergency freezes; governance's `ADMIN_ROLE` reopens.
The separate source route pause can also be lifted by its guardian. A local unpause cannot
bypass the source emergency flag. Pausing the keeper alone is insufficient:
operations are permissionless and can be called directly.

Paused `pokeSettle` may receive source funds and service Main debt, but does not
advance ordinary user collateral allocation. Main-ledger HOLLAR surplus claims
also respect emergency pauses. Verify the actual committee execution address
and rehearse both freeze and maintenance before launch.

## Fair Emergency Recovery

Recovery must include **all affected holders**, including holders who have not
requested withdrawal. Payment priority must not depend on being online or
requesting first. Preserve unpaid principal and reserve offline holders'
allocations as funding arrives.

The normal queue is FIFO. The source's proportional allocation among existing
unwinds is not an all-holder emergency allocation. Do not reopen ordinary FIFO
against partial funding and call that fair recovery.

The agreed approach is to defer incident-specific indexing and payout
implementation until needed. Keep affected exits frozen while preparing:

1. A canonical freeze snapshot covering deposits, transfers, escrowed shares,
   prior partial payments, settled claims, Main debt and source claims.
2. Per-holder protected principal, eligible yield and recovery allocation,
   reconciled across vaults and independently reviewed.
3. Explicit governance funding and, if approved, the contribution of compounded
   yield without consuming original principal.
4. A rehearsed execution path and reconciliation of old shares, queue entries
   and source claims, preventing duplicate entitlements.
5. Conditions for further staged payouts, continued freeze or reopening.

The current vault has no generic treasury extraction function and no complete
per-holder principal/yield recovery ledger. A governance call to Aave cannot
withdraw assets owned by the vault. Extracting compounded yield or implementing
partial all-holder settlement may require a narrowly scoped, reviewed upgrade.
Upgrade authority alone is not proof of a correct recovery calculation.

Direct HOLLAR donations to a vault retain normal FIFO behavior. The Main ledger
also supports targeted `fundPosition(0, amount)` for active holders and
`fundPosition(id + 1, amount)` for a started exit. Neither substitutes for a fair
incident-wide allocation plan. Funding mints no new vault shares.

Treasury protocol fees are separate: anyone can pay accrued collateral fees to
the configured recipient; spending those assets on recovery requires the
recipient's applicable treasury authority. There is no automatic fee sweep.

## Funded Rounding

Each vault has a donated collateral `roundingReserve`, excluded from share
backing, fees and ordinary withdrawal entitlements. It is not a HOLLAR loss
reserve or the removed operating buffer.

- Deposit issuance and started withdrawal promises round up; the reserve covers
  resulting dilution and actual aToken supply/burn rounding.
- Existing-holder backing must not fall because another user deposits or exits.
- `fundRoundingReserve` is permissionless, including while paused, and mints no
  shares or repayment right.
- Insufficient funding reverts atomically with `InsufficientRoundingReserve`.
  Replenishment permits retry without reducing the pending claim.
- Splitting requests can consume the finite budget. Monitor its minimum and
  target, native existential deposit, raw backing and custody dust protection.

Share-conversion views remain floor-rounded estimates; actual funded issuance
and exit promises can be higher. Rounding protection is not a substitute for
source solvency or funded governance recovery.

## Evidence and Open Responsibilities

[Principal rounding tests](../test/PrincipalRounding.t.sol) and
[recovery integration tests](../test/RecoveryE2E.t.sol) cover exact claims,
partial settlement, pauses, offline holders, source loss and staged funding.
The recovery model restores full backing before reopening. It does not verify
an unimplemented manual partial-payout mechanism or native liquidation engine.

[Native and long-duration evidence](route-execution-calibration.md) includes
explicit oracle/funding fixtures and must be read with those limitations.
See [RC verification](release-candidate.md#verification) for current test counts.

Before activation, the team still needs approved liquidity and execution limits,
funded rounding and recovery arrangements, timely Main-floor maintenance,
committee pause rehearsal and independent review. Incident-specific recovery
accounting is deferred, but its principal and fairness requirements are not.
