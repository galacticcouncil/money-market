# Separate ownership of Propeller yield

PR #62 keeps collateral shares backed by actual collateral and records source
yield separately in `PropellerYieldAccounting`. This is a fresh-deployment
change: storage compatibility alone does not migrate existing balances into the
new ownership ledger. Deploy the vault, source, Main ledger, Harvester and fee
controller together. Do not upgrade a funded older vault into this accounting.

The next version (`juicer-next`, [plan](next-version-plan.md) §1–§3) keeps that
ownership model and changes when and where it shows: yield is allocated at
events rather than on every transfer, a holder's funded earnings are part of
their vault balance and nobody claims them, and an exit takes its funded
earnings along. Its accounting storage differs from #62's, so it is a fresh
deployment too. This document describes that version.

## Ownership and entry

Allocation runs at equity events: a deposit, `requestRedeem`, an unwind start,
`rebalance` and the permissionless `sync()`. The Harvester calls `sync()` before
each harvest; the keepers call it after PRIME or collateral oracle updates and
at least every `SYNC_EVERY` (one hour). Each allocation checkpoints positive
source equity after reserving active Main debt, operating cash and the
realization fee needed to service accrued Main interest, and emits `Allocated()`.
Two USD8 quote quanta remain in active source backing to prevent floor rounding
from creating an unpaid debt tail; this is a bounded rounding residual, not a
percentage yield holdback. Entry is not checked against that backing on-chain:
the keepers compute the deficit off-chain and stop deposits through the vault's
`deficitStop` ([keeper runbook](../looper/README.md#deficit-stop)).

Checkpointed earnings split into user-owned source units and protocol fee units
at the current fee rate. Fee ownership vests at this checkpoint; subsequent rate
changes apply to subsequent allocations, including when the rate changes from
100% to zero. Nothing is payable to the treasury until actually realized. The
one exception is Main interest servicing: the reserve for already-accrued
interest is grossed up at the current rate, because the servicing slice pays the
fee in force when it is harvested. A rate increase can therefore write down
unconverted rewards by up to the unpaid interest times the change in
`fee / (1 - fee)`; see [protocol fees](protocol-fees.md).

Unconverted user and protocol units are junior to the active Main obligation.
They absorb source losses and accrued servicing needs before Main backing is
impaired. Checkpoints write down that ownership when needed; a recapitalization
to borrowed principal does not restore written-off earnings ahead of exits.
Already-funded collateral rewards remain backed collateral claims.

Execution costs are source losses too. Deployment slices and source ramps buy
PRIME for shares minted at the pre-swap source NAV, so each slice's swap cost,
bounded by its lane's approved shortfall, lowers every attached vault's source
equity. The next allocation absorbs it from unconverted rewards first, including
rewards of holders who did not trigger the deployment. Once those rewards are
exhausted the cost reaches Main backing. No contract waits for carry to restore
it: the keepers stop deposits and the source ramp when their deficit check
exceeds `DEFICIT_STOP_BPS` (50) and resume below `DEFICIT_RESUME_BPS` (25).
Deploying collateral that is already deposited (`rebalance`) is not gated by
that stop.

While source cash or execution costs await allocation (until `pokeSettle`), an
allocation event settles accounts at the current index without allocating or
writing down, and emits no `Allocated()`. Share transfers and redemption
requests continue; the harvester and the keepers' sync skip that vault until
settlement.

A completely worthless reward fund starts a new accounting epoch. Repeated
losses that leave only dust use lazy unit rescaling, avoiding unbounded growth
in accounting units without scanning holders or changing the underlying assets.

A lazy index awards reward-fund units to wallet-share holders at each
allocation. Deposits allocate before they mint and start at the current index,
so a newcomer captures no pre-entry yield. A transfer only settles its two
holders at the stored index: it allocates nothing and calls neither the source,
Aave nor the Main ledger. Units allocated before a transfer stay with the
sender, while yield accrued since the last allocation follows the balances
standing at the next one, so between events the recipient can receive that
interval's yield on the moved shares. No allocation, transfer or exit iterates
through holders. Waiting withdrawal shares continue earning until their unwind
starts, with a request-specific checkpoint preserving that entitlement.

`CollateralVault.totalAssets`, share conversions and fixed collateral withdrawal
claims continue to describe funded collateral. They do not include source
receivables. The synthetic token remains a health-factor support, not an asset
available to pay holders.

## Harvest and compounding

The Harvester first syncs every registered vault and selects a proportional
batch of eligible source units, capped by the source's harvest capacity. The source
also caps withdrawals at the configured deployment health-factor floor, including
when outside Main funding releases a large amount of source principal. The source
burns only the units being realized at their pre-withdrawal value. Other holders'
source-unit value is conserved apart from native-token rounding. Registry and
fee-configuration checks still bracket the entire atomic distribution.

Actual collateral receipts realize the protocol-owned portion, including its
share of source gains/losses and swap execution. The reserved servicing portion
pays Main interest first; the remaining owned-yield portion is supplied as
collateral and mints backed vault shares to the reward fund. It does not raise
every collateral holder's exchange rate and give past earnings to newcomers.
Unsolicited compound contributions retain their existing donation treatment.

The reward fund owns both unconverted source units and funded collateral shares.
Fund units are priced in HOLLAR precision from those assets; user-owned source
units are already net of vested fees. This preserves ownership even for accruals
smaller than one BTC base unit. Its already-funded collateral participates in future
yield; the corresponding new earnings increase existing fund-unit value. Nobody
claims to keep compounding.

## Balances without claims

Reward units are the only claim on the fund, pro rata on both of its parts: the
funded vault shares `F` that harvests minted to it, and the reserved source
shares `S` not yet harvested.

- `balanceOf(a)` is `walletOf(a)` plus `fundedOf(a)`, the holder's units over
  all units times `F`. The fund's own balance is its wallet minus the attributed
  `F`. Allocation weights use `walletOf`, the raw shares; a funded slice earns
  through the fund's unit value instead.
- Balances add up to `totalSupply` up to rounding, except while a waiting
  request holds units committed beyond its wallet (below): their funded slice
  shows in no balance until the unwind starts and folds it into the escrow.
- A transfer up to the sender's wallet moves wallet shares only. Beyond the
  wallet it also moves the units whose funded slice covers the rest, rounded up,
  together with their part of `S`, and emits a separate `Transfer` for that
  part. No third party's balance changes. More than `balanceOf` reverts
  `ExceedsBalance`. Allowances apply to the full amount.
- `earnedAssets(a)` values everything the holder's units own in collateral: the
  funded slice already in the balance plus the pending source part. The UI shows
  the pending part separately; it is an estimate that can still fall with source
  losses or realization costs.
- Balances move without transfers, as with Aave aTokens. A harvest that
  compounds into the fund raises every unit holder's slice. An allocation can
  lower a displayed slice slightly, because new units re-split `F` and `S`, by
  at most the holder's pro-rata share of the new yield (Lean
  `ShareBook.allocate_slice_dip`); no holder's value drops. The plan routes
  integrations through a wrapped share (wjETH), which this code does not have
  yet.

`claimYield`, `claimableShares`, `vestedShares` and the separately vested claim
of exited owners are gone.

## Withdrawals and fee consistency

`requestRedeem(x)` escrows up to `x` wallet shares. Beyond the wallet it commits
to the request the owner's units whose funded slice covers the rest, capped at
the slice the owner has; a larger `x` does not revert. Only the owner can call
`requestRedeem(type(uint256).max, owner)`, which takes the wallet and every unit.

At unwind start the owner receives the units the escrowed shares earned while
waiting. The exit then takes the units committed at request time plus the
escrowed shares' proportion of the owner's units (escrow over wallet plus
escrow), so a request for the whole wallet takes all of them. Those units are
burned and split both fund assets pro rata: the source part joins the unwind,
and the funded shares move from the fund into the escrow before the vault quotes
the collateral owed (`RewardsFolded`). No other holder's slice or unit price
moves, the next holder's source allocation is preserved regardless of exit
processing order, and nothing stays attributable to the owner after a full exit.
The source records the actual principal basis separately from that yield,
preserving the exit's earned execution allowance. The original-owner cash,
indexed Main debt and late-recovery rules from #60 remain in force. Collateral
claims are not silently reduced by a funding deficit.

Unconverted user yield that follows an exit settles through its original owner's
HOLLAR surplus claim. Its corresponding protocol units join that unwind too.
Their ownership was already separated at checkpoint: they are not a second fee
on the user's net reward. Both portions share actual execution costs. Active
source yield reserved for Main servicing also records its fee at unwind start.
The Main ledger reserves the maximum fee from partial receipts and reduces it
as source costs arrive. It transfers the fee only when that source claim closes,
so a late cost cannot retroactively make a paid fee consume principal. Partial
surplus claims exclude this reserve, exposed through `surplusOf(id)`.
Explicit Main recovery donations and recovered source principal are not charged.
When Main funding or outside repayment releases source capital, the ledger
reclassifies that capital without a yield fee before a newcomer can enter.

Owned source withdrawals can leave different vaults with different source cost
bases. Following a loss, a global source recapitalization at unit NAV is not proof
that every vault's Main obligation is restored. Recovery must check and, when
necessary, explicitly fund each active Main cohort, including offline holders,
before reopening. The recovery tests account for these outside contributions;
they do not treat them as strategy income.

Exit fees accrue as HOLLAR to the existing fee controller, separately from
ordinary harvest fees held in the deposited collateral. Treasury claims use the
same `claimProtocolFees(asset)` entrypoint. At a 100% rate newly checkpointed
yield leaves no user-owned earnings to fund Main servicing or an exit allowance;
this can delay settlement. Previously allocated rewards retain their ownership.
The removed on-chain guard also blocked entry at that rate while Main interest
exceeded available net funding; the keepers' deficit check compares active Main
debt with source backing only.
Fee policy and funding constraints do not insure the position.

## Reinvestment and execution policy

Newly compounded collateral records borrowing capacity. `rebalance` can use that
capacity without waiting for the five-percentage-point price-movement band. It
borrows only within the current reserve LTV, routes HOLLAR synchronously into the
source, and retains the existing pause and outstanding-exit guards; it no longer
checks underfunding.
Deposit and rebalance execution live in the vault's immutable helper to preserve
the EIP-170 runtime limit; the helper writes no vault storage directly.

Source ramping excludes positive, unconverted carry from its borrowing budget:
that carry is waiting to buy collateral, not to increase PRIME leverage again.

The keeper checks harvest availability each cycle, harvests before optional
ramping, and runs Main maintenance/reinvestment after a successful harvest.
Between harvests it calls `sync()` so allocation follows prices.
Empty harvests do not create transactions. A keeper attempt is not a guarantee
of execution or a promise of a particular APY.

Main servicing uses the fresh net harvest to cover actual execution costs when
its oracle-valued slice is insufficient. Only that transaction's fresh reward
collateral can supplement the slice; existing funded collateral is unavailable.
Unused HOLLAR allowance funded this way releases an equal source claim back to
the existing reward fund, preserving unit ownership across the next checkpoint.

The source's economic retention and minimum-yield policy remain separate launch
parameters. Correct ownership does not itself eliminate their wait. Reducing a
reserve requires an execution-cost coverage model; this PR does not authorize
lower production reserves, widen slippage, or claim that retained yield will be
converted within a fixed time. Shared route budgets and liquidity-based partial
trade limits remain in the execution-controls workstream.

## Validation and rollout

`test/YieldEntryFairness.t.sol` covers entry before harvest, entry followed by an
exit before harvest, transfers within and beyond the wallet, transfers between
allocation events, waiting requests, the exit fold, continued compounding in
escrow, fee vesting, losses and reinvestment below the old LTV trigger. The original
capture tests first failed against the draft contracts; they are prevention
regressions in this implementation. `test/YieldCheckpointGas.t.sol` checks that a
transfer calls neither the source, Aave nor the Main ledger, and
`invariant_balancesAddUp` that balances never exceed the supply. Fee, multi-vault,
source compatibility, settlement and invariant suites must also pass on the final
code. The removed underfunding views live on as the test helper
`test/helpers/Deficit.sol`. The Lean `YieldShares`, `Allocation` and `Redemption`
specs model the next version's balances, allocation and exit fold
([formal](../formal/README.md)); bridge parity with the Solidity is still to run.

The earlier exact-rational study and dated evidence below are historical design
artifacts, not proof of this implementation:

- `scripts/propeller/yield-ownership-study.mjs`
- `docs/evidence/yield-ownership-2026-10-02/`

Review the final PR validation record for the tested commit, runtime sizes and
remaining native-chain activation gates. No merge, deployment or production
parameter change is performed by this implementation work.
