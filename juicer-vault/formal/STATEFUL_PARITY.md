# stateful public-call comparisons

`PublicCalls.lean` composes the existing integer allocation, account, exit, Main-debt,
source-batch and redemption models into the raw executable public-call machine.
`PublicCertificates.lean` wraps that machine with a decidable post-state certificate: a raw
success is preserved exactly when it satisfies the combined invariant, while a rejected result
rolls back with the model-only code 98.
`SolidityDispatch.lean` maps every fixture opcode 0–30 to a typed target, selector and action
argument projection. `check-dispatch.py` checks that table against both Solidity `perform`
functions, and the universal `solidity_dispatch_corresponds` theorem equates the typed dispatcher
with `rawRunCall` for every action.
`LeanStatefulParity.t.sol` runs the actual vault, accounting, Main and delegatecall logic
from deployment. `LeanMarketStatefulParity.t.sol` adds the actual Harvester and fee controller,
with changing source values, collateral prices, debt observations and execution costs.
`LeanRescaleStatefulParity.t.sol` drives the same public system through four lazy rescales.
`StatefulReplay.lean` replays the recorded actions and compares every
post-call snapshot and success/revert outcome. it also checks the holder, request,
Main-cash/debt and collateral partitions and the lazy liability bound after every call. its
computed certificate also carries proofs of collateral custody, source/cash partitions and the
combined holder/waiting-request lifecycle and operational request/array partitions for every
accepted post-state. each row must satisfy `FixtureAction` and `ValidSolidityAction`; 21 opcodes
satisfy the latter from the certified pre-state alone, transfers additionally require ordinary
holders and bounded destinations, claims require started requests, and sync requires consistent
account/request epochs and scales. the remaining opcodes have the input conditions described
below, including queue backing, batch budgets and source capacity. all 31 have structural rules;
the only fallback admits raw reverts. the replay still certifies every resulting state and advances
with the raw typed dispatcher, so no checked-call guard can hide a raw transition mismatch.

Lean starts with the fixture's known genesis configuration and keeps its own predicted
state throughout a campaign. Solidity snapshots are comparison outputs only; they never
initialize a later Lean state. A mismatch reports the seed file, first failing step,
action and field. Reverted calls preserve the previous model state, and the Solidity
runner independently checks rollback of the compared fields.

## run

From `juicer-vault/formal`, with the pinned Lean/Mathlib and Foundry toolchains:

```sh
python3 check-stateful.py
python3 check-stateful.py --seed 9 --count 8 --depth 512
python3 check-stateful.py --fixture market --count 1
python3 check-stateful.py --fixture rescale --count 1
```

The default runs eight campaigns per fixture with 192 pseudorandom actions after a deterministic
prefix, then drains and claims the queues. Half of the campaigns create 71 requests
before the first repayment, crossing both the 32-request settlement limit and the
64-cohort source-accounting limit. Seeds and depths are configurable; a failing trace
is saved under `.stateful/trace-<seed>.jsonl`, `.stateful/market-<seed>.jsonl` or
`.stateful/rescale-<seed>.jsonl`. Run a single seed with `--count 1`;
each invocation accepts up to eight seeds. A completion marker rejects interrupted
traces, and the three coverage JSON files record successful actions, revert classes and exercised
queue/batch/claim boundaries. Required boundary cases must actually execute.
`check-runtime.py` includes the default campaigns and their Lean replay.

The checked corpus contains 48 campaigns and 22,609 recorded steps, including 16,315 vault calls,
637 Harvester/fee-controller calls and 5,657 environment actions. The longest sequence has 720
steps. the baseline and market corpus passes on the original and allowance-fixed Solidity; the
fixed branch rejects one additional `transferFrom` call with `InexactShares` (baseline seed 9,
step 596). the rescale corpus targets the corrected branch and intentionally distinguishes its
ceil-shifted result from the earlier floor behavior.

| fixture | seeds | random depth | recorded steps | expected reverts |
| --- | --- | --- | --- | --- |
| baseline | 1–8 | 192 | 2,419 | 596 |
| baseline | 9–16 | 512 | 5,005 | 1,640 original / 1,641 allowance-fixed |
| market | 1–8 | 192 | 2,598 | 463 |
| market | 9–16 | 512 | 5,194 | 1,034 |
| rescale | 1–8 | 192 | 2,321 | 352 |
| rescale | 9–16 | 512 | 5,072 | 846 |

All campaigns pass coverage gates and 2,000 corrupted-output checks. Incomplete traces
are also rejected. Longer campaigns use a higher test gas budget for snapshot instrumentation;
these gas totals are not estimates for public vault calls.

Each campaign exercises deposits, deferred borrowing, external Main repayment, sync,
fund donations, approvals, direct/delegated transfers, partial/full/delegated requests,
cooldowns, bounded starts, partial source receipts and pool repayments, repeated claims,
receiver selection, local/deposit/source pauses and rejected calls. Outside Main
repayment releases capital for reward allocation without seeding accounting storage.

The snapshot contains supply/assets, collateral and synthetic custody, reserve use,
source shares/principal/freed cash, reinvestment, queue totals/cursors, reward book,
eight holder accounts, sixteen allowances, every request and every Main position.
Stored account units are read with `vm.load`; the runner never writes protocol storage
or impersonates a vault-only caller. The existing fingerprint/layout checks pin that
read. Each replay also rejects deliberate changes to supply, escrow, reward units,
holder balance, allowance and outcome fields, guarding against a disabled comparison.

## market campaigns

The market fixture exercises nonzero protocol fees, harvests that mint funded reward shares,
caller-funded compounding, source execution costs and fee claims. Debt accrual changes the
observed debt and normalized variable-debt index; borrowing and repayment independently lose
small debt-token amounts to rounding. The snapshot includes a pool repayment counter, so a
retry must execute twice to satisfy its coverage gate. Collateral-price drops start active
Main deleveraging, block deposits, and settle across partial receipts and pauses. Source-price
losses and recoveries interleave with allocations, transfers, waiting requests and exits.

The model composes the existing allocation, harvest split, fee vesting/settlement, Main cohort,
source batch and claim functions. It separately predicts oracle quotes, servicing sales,
protocol reserve draws/returns, fee custody, synthetic top-ups and the public guards. The
fee/cash/source partitions and source custody backing are checked after every successful step.
The extended snapshot includes source NAV/custody, fee balances, normalized debt index, active
source claims, costs, protocol reserves, the delever target, harvest time and all frozen batch
fields. Private batch fields are read with `vm.load`, protected by layout and fingerprint checks.

Coverage gates require successful harvests, reward mints, interest servicing, repayment retries,
peg top-ups, source costs, source/harvest fee collection, price-driven delever starts/completions,
source losses and protocol fee claims. Rejected harvest minima and deposits during deleveraging
must also occur. Corruption checks cover the additional custody, index, cost, fee, target and
repayment-counter fields. Genesis selects a fixed fixture configuration from the action header;
no observed Solidity state initializes the prediction.

## rescale campaigns

the rescale fixture lowers the funded source to a positive residual, deposits through the public
vault at that low denominator, and obtains ray-scale shares without writing accounting storage.
an ordinary account and waiting request then remain stale while repeated public `sync` calls cross
scales 64, 128, 192 and 256. every campaign must settle the stale account, start the stale request,
perform transfers and partial/final claims after a rescale, execute rejected calls without state
changes, write off the reward epoch, refill it and mint funded rewards again.

the coverage gate independently recomputes the old floor-shifted account and request claims and
requires a state where they differ from the corrected ceil-shift result. this makes the long replay
sensitive to the PR #74 correction, beyond merely observing a nonzero scale. rescale-step mutation
checks alter total units, reward index, epoch, scale, stale account/request fields and the expanded
market fields. these are controlled source repricings backed by fixture tokens, not a claim about
the cost or feasibility of producing the same path in a live market.

## fixture boundary

all three fixtures use 18-decimal mock tokens, 75% collateral LTV, 98% synthetic LT, exact token
transfers and four funded public actors. The baseline uses `MockYieldSource` at par, fixed
one-dollar prices, a fixed debt index and zero fees/costs. The market fixture uses
`StatefulYieldSource`: source shares price a funded HOLLAR pool, and revaluation explicitly
mints/burns mock HOLLAR to back the new NAV. It releases unwind claims synchronously, with
independently limited pulls and recorded execution costs. The real Harvester calls its
`harvestFor`, the vault's `burnYieldShares` and `compound`, and the real fee controller collects
fees. `MockSwapper` uses the pool's oracle prices with a bounded execution haircut.

The pool accrual action increases debt using the new index and an explicit rounding rule.
Separate borrow/repay loss controls exercise observed-debt accounting and the index-dependent
rounding quantum. This is a controlled external-observation fixture, not Aave's complete scaled
token implementation. Outside repayments, reserve deposits and Main funding are explicitly
funded environment actions, not trading profit. Market changes, time advances and liquidity
controls are also recorded actions.

the baseline and market campaigns stay below rescale thresholds and require `unitScale == 0`.
the dedicated rescale campaigns reach cumulative `unitScale == 256` with an ordinary holder and
waiting request left stale from scale zero. ceil-shifted indices keep aggregate claims within
`totalUnits` and remain defined at the four-shift boundary.

separate integration checks cover three other fixture boundaries. `LeanScaledDebt.t.sol` runs 516
mint, burn and index steps against Aave core v3's actual `VariableDebtToken` 1.19.3, with a mock
Pool that drives the normalized index, and Lean replays every scaled balance and expected revert.
`SharedFlowHarness.t.sol` runs repeated harvests for two real vault instances sharing one SubLoop
and Harvester. its ICE sequence uses the actual SubLoop with `MockIntentDispatch` through entry,
expiry, permissionless reconciliation, exit, a missed callback, a late callback and final pull.

the deployed Aave Pool and reserve lifecycle, live pallet/solver execution, malicious tokens,
reentrancy, arbitrary oracle/configuration changes and the full uint256 input space remain outside
these fixtures. the integration checks are bounded executable comparisons, not live-chain tests.

this is differential execution evidence for the exercised public control flow. the checked
machine has universal preservation theorems for successful calls and arbitrary finite action
lists from a certified input. `ValidSolidityTrace` defines the raw domain as source-pinned fixture
actions admitted by a structural input theorem or a raw revert. successful post-state certificates
are checked separately and are no longer an admission fallback.
`validSolidityTrace_invariant` and `validSolidityReachable_invariant` prove preservation through
arbitrary finite traces in that domain, while the default replay checks membership for all 7,338
recorded actions. a fabricated orphan-claim storage state is a concrete counterexample to raw
preservation over unrestricted states and is excluded by the domain.
account/request epoch and scale metadata has a separate preservation proof for every raw action:
`rawReplay_genesis_metadata` covers arbitrary finite histories, including rollback and
unsupported opcodes. `rawReplay_genesis_callBounds` separately proves source pull/cost rates and
fee rates remain at most 10000 basis points, and all stored request owners remain ordinary, across
arbitrary finite fixture-call histories. it uses only initial bounds and `FixtureAction`, including
its bounded setters and ordinary request creators; financial invariants and successful post-state
certificates are unnecessary. `WaitingOwners` follows from the stronger all-request property.
the replay checks these properties as diagnostics, including owners of already-started requests.
initialization, zero active fees, queue backing, credit readiness and harvest capacity still need
broader inductive proofs.

the typed opcode theorem and source checker establish fixture-dispatch correspondence.
`check-bytecode.py` separately binds 11 reproducibly compiled production artifacts and the relevant
ABI selectors to reviewed hashes. it does not prove the internal contract bodies equivalent to
`rawRunCall`. sync, requestRedeem and deposit have structural preservation under account/request
metadata consistent with the book history. deposit also requires zero reward index at zero supply;
replay checks these input premises throughout all 7,338 steps. requestRedeem requires an ordinary
owner and deposit a bounded receiver, both supplied by the fixture domain. rebalance is proved
under a zero-fee remainder at zero active source remainder. settlement loops preserve the
invariant for any iteration count under backed owed collateral and a Main position count equal
to the unwind cursor plus one. pokeSettle composes source pulls, fee-backed batch credits, Main
payments and settlement; its additional premises constrain source rates, batch weights and
remaining budgets. harvest preserves the invariant when its post-checkpoint amount fits source
capacity. startUnwinds preserves the invariant over arbitrary loop lengths under consistent
metadata, queue backing, ordinary waiting owners and fee rates at most 10000 basis points.
its exact raw-body correspondence includes the deferred cursor update. replay checks these
premises too. the reachable-call admission theorems now derive the rate/owner/metadata premises
from the history: `startUnwinds` still needs queue backing, and `pokeSettle` needs queue backing and
credit readiness. inductive preservation of the remaining five additional input conditions and
semantic equivalence from compiled bytecode to the Lean transitions remain outside this result.
