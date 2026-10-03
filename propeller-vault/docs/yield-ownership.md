# Separate ownership of Propeller yield

PR #62 keeps collateral shares backed by actual collateral and records source
yield separately in `PropellerYieldAccounting`. This is a fresh-deployment
change: storage compatibility alone does not migrate existing balances into the
new ownership ledger. Deploy the vault, source, Main ledger, Harvester and fee
controller together. Do not upgrade a funded older vault into this accounting.

## Ownership and entry

Before a deposit, ordinary share transfer, withdrawal snapshot or harvest, the
vault checkpoints positive source equity after reserving active Main debt,
operating cash and the realization fee needed to service accrued Main interest.
Unfunded Main debt still blocks entry. Two USD8 quote quanta remain in active
source backing to prevent floor rounding from creating an unpaid debt tail;
this is a bounded rounding residual, not a percentage yield holdback.

Checkpointed earnings split into user-owned source units and protocol fee units
at the current fee rate. Fee ownership vests at this checkpoint; subsequent rate
changes apply to subsequent allocations, including when the rate changes from
100% to zero. Nothing is payable to the treasury until actually realized.

Unconverted user and protocol units are junior to the active Main obligation.
They absorb source losses and accrued servicing needs before Main backing is
impaired. Checkpoints write down that ownership when needed; a recapitalization
to borrowed principal does not restore written-off earnings ahead of exits.
Already-funded collateral rewards remain backed collateral claims.

A completely worthless reward fund starts a new accounting epoch. Repeated
losses that leave only dust use lazy unit rescaling, avoiding unbounded growth
in accounting units without scanning holders or changing the underlying assets.

A lazy index awards
reward-fund units to the collateral holders who earned them. New deposits start
at the current index. Transfers retain previously earned rewards with the sender;
the recipient earns subsequently. No checkpoint, transfer or claim iterates
through holders. Waiting withdrawal shares continue earning until their unwind
starts, with a request-specific checkpoint preserving that entitlement.

`CollateralVault.totalAssets`, share conversions and fixed collateral withdrawal
claims continue to describe funded collateral. They do not include source
receivables. The synthetic token remains a health-factor support, not an asset
available to pay holders.

## Harvest and compounding

The Harvester first checkpoints every registered vault and selects a proportional
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
yield; the corresponding new earnings increase existing fund-unit value. An
owner does not need to claim repeatedly to keep compounding.

`claimYield(receiver)` exchanges the caller's reward units for available funded
vault shares. It never pays an unconverted receivable as collateral. A partial
claim leaves the remaining fund units and their source value owned. The UI shows
claimable collateral separately from estimated yield awaiting conversion, and
retains the claim action even when ordinary wallet shares have been withdrawn.

Ordinary reward claims redeem fungible reward-fund units at the current quoted
fund NAV, capped by available unvested collateral shares. Claim liquidity is
shared: an early claimant can take more than its proportional funded slice,
leaving the remaining fund with more source exposure. Estimated source value
can fall with market losses or realization costs. The separately vested shares
of an exiting owner are excluded from that shared liquidity. This reward-fund
tradeoff does not change the funded principal claim of the collateral shares.

## Withdrawals and fee consistency

At unwind start, the withdrawing holder receives the waiting request's earned
units. The owner's proportional fund allocation splits both its assets:
unconverted source units join the unwind, while funded reward shares become a
separate, vested claim for that owner. This preserves the next holder's source
allocation regardless of exit processing order. Vested shares keep earning for
their owner until claimed. The source records the actual
principal basis separately from that yield, preserving the exit's earned
execution allowance. The original-owner cash, indexed Main debt and late-recovery
rules from #60 remain in force. Collateral claims are not silently reduced by a
funding deficit.

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
this can delay settlement. Previously vested rewards retain their ownership.
Entry is blocked at that rate while Main interest exceeds available net funding,
even if gross source equity exceeds the debt.
Fee policy and funding constraints do not insure the position.

## Reinvestment and execution policy

Newly compounded collateral records borrowing capacity. `rebalance` can use that
capacity without waiting for the five-percentage-point price-movement band. It
borrows only within the current reserve LTV, routes HOLLAR synchronously into the
source, and retains the existing pause, funding and outstanding-exit guards.
Deposit and rebalance execution live in the vault's immutable helper to preserve
the EIP-170 runtime limit; the helper writes no vault storage directly.

Source ramping excludes positive, unconverted carry from its borrowing budget:
that carry is waiting to buy collateral, not to increase PRIME leverage again.

The keeper checks harvest availability each cycle, harvests before optional
ramping, and runs Main maintenance/reinvestment after a successful harvest.
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
exit before harvest, transfers, waiting requests, partial reward claims, continued
compounding in escrow, fee vesting, losses and reinvestment below the old LTV trigger. The original
capture tests first failed against the draft contracts; they are prevention
regressions in this implementation. Fee, multi-vault, source compatibility,
settlement and invariant suites must also pass on the final code.

The earlier exact-rational study and dated evidence below are historical design
artifacts, not proof of this implementation:

- `scripts/propeller/yield-ownership-study.mjs`
- `docs/evidence/yield-ownership-2026-10-02/`

Review the final PR validation record for the tested commit, runtime sizes and
remaining native-chain activation gates. No merge, deployment or production
parameter change is performed by this implementation work.
