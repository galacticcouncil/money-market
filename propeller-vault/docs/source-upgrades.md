# Yield Source Upgrade Boundary and Future Rotation

Status: 2026-09-23 RC design and compatibility tests. **Strategy rotation is
not implemented or enabled.** This does not resolve the
[RC activation gates](release-candidate.md#activation-gates). No production governance
action, adapter selection, migration budget or slippage approval is implied.

## Decision

Keep the existing source proxy as the long-lived accounting endpoint. A future
reviewed upgrade may retain its legacy PRIME position while allocating recovered
HOLLAR to another strategy behind that same endpoint. Implement the rotation
engine only when a replacement venue is selected and its risks are understood.

Define and test the upgrade boundary now. Do not rely on developing a migration
under emergency time pressure, or treat upgrade authority as proof that an
arbitrary new implementation is compatible.

No production Solidity changes are made for this preparation. The new Solidity
implementations live only in `test/SourceUpgradeCompatibility.t.sol`; they are
an append-only marker implementation and a deliberately broken counter fixture.
Neither is a strategy adapter or a production upgrade candidate.

## Compatibility Contract

The endpoint must preserve the meaning, units and ownership of its existing API:

| Surface | Required continuity |
| --- | --- |
| Proxy and custody | Keep the source address and its existing Aave borrower/custody identity. A new implementation must continue managing assets and debt already held there. |
| Storage and permissions | Preserve inherited storage, packed fields, mappings, roles, initializer state and pause state. Do not recycle existing storage or reset accounting. |
| Source shares | Preserve each collateral vault's shares and the aggregate supply. Internal strategy moves cannot burn/reissue users' source shares or rewrite their cost basis. |
| `equityOf(vault)` | Remains live-share equity in USD8, excluding withdrawal liabilities. Report truthful combined backing, not gross assets or an optimistic value for frozen claims. |
| `totalEquity()` | Retain the current distinction between gross equity, uncredited unwind backing and freed cash already reserved for claims. Reconcile all components without double-counting. |
| `requestUnwind` / `pendingUnwindOf` | Preserve outstanding HOLLAR18 obligations and original ownership, including freed-but-unpulled funds. Internal rotation is not a user redemption. |
| `pullFreed` / `freedOf` | Report and transfer actual reserved HOLLAR for that vault. Rotation proceeds cannot masquerade as user-settlement cash. |
| `unwindExecutionCost` | Keep a continuous cumulative HOLLAR18 counter per collateral vault. Count each realized eligible expense once; never reset it when a child strategy changes. |
| Harvest | Distribute only legitimate surplus, preserving fee and Main-servicing rules and excluding user claims, migration principal and reserved execution yield. |
| Monitoring | Preserve deficit and emergency signals. A new strategy must not conceal a legacy loss or permit deposits using unrecovered funds as liquid backing. |

The current USD8/HOLLAR18 valuation assumptions are part of this boundary. A
new accounting currency, different oracle convention or changed claim semantics
requires explicit review of the immutable Main-debt ledger, not just an adapter.

The ledger tracks active holders and exit cohorts, not individual child
strategies. Its source cash/cost batches, debt units, accrued interest and
original-owner late recoveries must survive an upgrade. A compatible aggregate
source may allow the ledger to remain unchanged; that is a design constraint,
not a guarantee that it supports every future strategy.

In particular, a reset execution-cost counter makes its subtraction from
`sourceCostCheckpoint` underflow. An incorrectly increased counter can also
misallocate expenses. Monotonicity alone is insufficient: expenses must retain
their economic meaning and must not be replayed, fabricated or charged to
principal. Authorized UUPS upgrades do not enforce these rules automatically.

## Current Limits

- `CollateralVault.setYieldSource` checks the old source's shares and pending
  unwinds. It does not migrate the Main ledger, cost checkpoints or harvesting.
  Treat it as deployment wiring, not live migration approval, even if an unusual
  drained state makes its guards pass. Ordinary withdrawals leave locked-share
  exposure; do not rely on that observation as a universal migration invariant.
- The deployed `Harvester` implementation is non-upgradeable and has immutable
  source/token bindings. A different or multi-asset strategy may require a new
  harvester and coordinated source/fee bindings. Existing `prime()`/`subLoop()`
  bindings cannot simply be assumed venue-neutral.
- The Main-debt ledger is non-upgradeable and the current vault disallows its
  live replacement. Resetting it would lose obligations and ownership.
- The collateral vault has only 195 runtime bytes of headroom in the verified
  London build. Keep strategy management outside that vault where possible;
  neither storage gaps nor proxy upgradeability waive native code/gas limits.
- Current emergency pauses are not a migration mode: the source emergency pause
  stops ordinary unwinds. A future rotation needs explicitly reviewed controls
  that freeze user flows/new risk while retaining required repayment operations.

## Future Gradual Rotation

This is the preferred design direction, not implemented behavior:

```text
Stable source proxy and existing per-vault accounting
    legacy PRIME assets/debt + idle owned cash + new strategy adapter(s)

legacy unwind -> repay legacy loop debt -> actual free HOLLAR
              -> reserve servicing/exit obligations -> bounded new allocation
```

Old and new strategies may operate concurrently. Each step can invest recovered
net HOLLAR while the rest of the old position remains invested. There is no need
to wait for the last legacy position to close before starting the new strategy.

Main debt can remain outstanding against correctly accounted combined backing;
rotation need not repay and reborrow all Main debt. This requires explicit risk
checks and continued interest servicing. It is not permission to borrow an
additional Main position to prefinance the replacement strategy.

The step budget must exclude reserved exit cash, settlement allocations,
committed Main servicing and source-debt repayments. Never invest the gross
proceeds of selling old collateral before repaying the debt they secure. Both
old and new strategies must satisfy their own health/liquidity constraints;
aggregate gross exposure, not only net NAV, needs a cap.

Migration trades can incur costs on both legs. Charge only the approved, actually
funded yield/recovery budget; do not erase principal or fixed user claims. Do not
double-count migration cash alongside the old shares/receivable it replaced.
Keep internal migration accounting separate from ordinary `requestUnwind`
liabilities and the Main ledger's source-settlement stream.

### State and Controls

Proposed states: `Idle -> Prepared -> Rotating -> Completed`, with `Paused` and
`RecoveryRequired` branches. These names are illustrative, not a new API.

1. Governance approves a reviewed adapter, target exposure, tranche limits,
   loss budget, oracle policy and explicit completion conditions.
2. Snapshot/reconcile both collateral vaults, all outstanding exits, fees,
   source costs, debt and custody before enabling steps. Initial rotation should
   freeze new deposits, borrowing and user flows unless fair concurrent-flow
   semantics have separately passed review.
3. Permissionless keepers execute only the approved bounded steps. They cannot
   choose arbitrary recipients, replace adapters or weaken swap floors.
4. Preserve already-started exits and delayed requests. Pausing claims must not
   reset their delay, owner, interest allocation or collateral promise.
5. The guardian can halt new allocation while necessary repayment remains
   possible. Governance may pause, change an approved plan or enter recovery;
   no automatic slippage widening or unreviewed strategy selection is allowed.
6. Complete only after old assets, debt, fees, harvest balances and liabilities
   are explicitly reconciled. Residual claims cannot disappear under a relative
   dust tolerance. Reopen flows only after readiness/backing checks pass.

Exact selectors, governance delays and migration limits will be specified with
the future implementation. This document does not approve numeric defaults.

### Recovery and Reversal

A frozen old position cannot finance a new one. Retain the original holders'
claim records and conservatively report the impairment. Governance funding is
real external capital; receiving it must not silently transfer old recoveries
to the treasury or advantage whichever users claim first.

For the first rotation implementation, a deficit should halt new allocation
until the old obligations are genuinely funded. Restarting investment while old
claims remain frozen requires additional per-strategy/per-cohort legacy-claim
accounting and a reviewed fair recovery procedure. It is not covered by simply
keeping the source proxy address unchanged. The existing FIFO collateral queue
is not an all-holder emergency settlement system.

After assets have moved, "rollback" is not just reinstalling the old bytecode:
the old implementation may ignore new-strategy assets, debts or storage. Any
reversal is another accounted unwind/reallocation. Keep the new implementation
in a safe paused/repayment state until a reviewed forward fix or reversal is
available. Never discard new state merely to restore an old implementation hash.

## Implementation When Needed

1. **Venue and accounting specification.** Select the adapter, oracle and yield
   asset; establish redemption latency, loss behavior and realistic capacity.
   Define aggregate NAV, cost basis, per-vault attribution, custody/approvals,
   servicing reserves and compatibility with the existing immutable ledger.
2. **Rotation implementation.** Extend the stable source with bounded legacy
   unwind/new allocation controls and reviewed external modules as needed.
   Preserve legacy custody, share accounting and counters; adapt harvesting,
   fee bindings, keeper operations and read-only readiness checks together.
3. **Upgrade and release verification.** Compare against the actual deployed
   layout and bytecode, run differential stateful upgrade tests, re-run economic
   and liquidity simulations, rehearse the exact governance proposal on a fresh
   `hdx.tarn` Chopsticks fork, and obtain independent review before activation.

Do not introduce a new adapter merely to exercise this plan today. No automatic
allocation optimizer, cross-vault recovery sweep, live ledger replacement or
general emergency distribution engine is included in this preparation.

## Required Future Tests

- Compare uninterrupted operation with upgrading the identical live state:
  shares, NAV, custody, debt, fees, principal promises and eventual payouts.
- Exercise migration with pending withdrawal delays, partial settlements,
  accrued Main interest and source loss, paused vaults, and late recoveries after
  a user's collateral exit has completed.
- Upgrade mid-way through a 64-record source-allocation batch, including more
  than 64 exits, unallocated cash/cost and new receipts during a frozen batch.
- Interleave old-strategy unwinds and new allocations; prove cash conservation,
  no extra Main borrowing, no appropriation of exit funds, no artificial yield
  or cost-basis resets, and no double-counting of assets in transit.
- Test old/new strategy failures independently: failed swaps, asynchronous or
  partial returns, oracle moves, loss, zero NAV, frozen assets and bad adapters.
- Cover guardian stops, governance restarts, both possible claim orders, offline
  holders, recovery funding and an interrupted migration that cannot be reversed
  by reinstalling old code.
- Recheck native code size, creation gas, per-step gas, custody registration,
  adapter approvals, fee/discount wiring and liquidity under six TVL levels and
  90-day bull/bear/seesaw paths. Mocks do not establish native market capacity.

## Checks Added Now

`SourceUpgradeCompatibilityTest` uses real vault/source/ledger/fee code with
mock Aave/router boundaries. Seven focused cases cover a live UUPS upgrade,
exact differential exit/harvest/Main-servicing continuation, waiting requests, local/emergency pauses,
pending costs/receipts credited once, late original-owner recovery, persistent
underfunding, authorization/reinitialization and a deliberately reset counter.
The reset-counter case demonstrates a bad upgrade that *installs successfully*
but breaks settlement. It is not an automatic on-chain upgrade rejection guard.

The [storage baseline](evidence/source-upgrades-2026-09-23/subloop-storage.json)
pins the local SubLoop layout, including inherited fields and gaps. The
layout checker compiles only storage output using the pinned local compiler,
verifies artifact source hashes, and leaves Forge bytecode/cache outputs alone.
It ignores unstable compiler AST IDs but compares slots, packed offsets and
recursive types. Only append-only additions beyond the preserved layout pass.
Gap consumption and compiler changes conservatively require separate review.

This is a research baseline, not a deployed artifact. Before production, freeze
the actual release implementation, source hashes, full storage layout and build
settings. Do not regenerate the baseline to make a failing candidate pass.
Layout compatibility does not prove economic semantics, assembly-slot safety,
external protocol compatibility or the safety of arbitrary upgrade authority.

From the repository root, run Forge jobs serially:

```sh
forge test --root propeller-vault --offline --evm-version london \
  --match-contract SourceUpgradeCompatibilityTest --match-test test_upgrade -vv
node scripts/propeller/check-source-storage.mjs
node scripts/propeller/check-source-storage.mjs \
  --artifact propeller-vault/out/SourceUpgradeCompatibility.t.sol/SubLoopUpgradeProbe.json
node --test-reporter=tap scripts/propeller/source-storage.test.mjs
```

`SOLC` or `--solc` may point to the pinned installed Solc binary; the checker does
not download a compiler. `--write-baseline` is for an explicitly reviewed new
baseline path and refuses to overwrite an existing baseline. Current verification
results and remaining limits are recorded in the
[verification evidence](evidence/source-upgrades-2026-09-23/verification.json).
