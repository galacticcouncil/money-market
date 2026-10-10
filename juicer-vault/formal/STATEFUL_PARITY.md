# stateful public-call comparisons

`PublicCalls.lean` composes the existing integer allocation, account, exit, Main-debt,
source-batch and redemption models into an executable public-call machine.
`LeanStatefulParity.t.sol` runs the actual vault, accounting, Main and delegatecall logic
from deployment. `LeanMarketStatefulParity.t.sol` adds the actual Harvester and fee controller,
with changing source values, collateral prices, debt observations and execution costs. `StatefulReplay.lean` replays the recorded actions and compares every
post-call snapshot and success/revert outcome. It also checks the holder, request,
Main-cash/debt and collateral partitions and the lazy liability bound after every call.

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
```

The default runs eight campaigns per fixture with 192 pseudorandom actions after a deterministic
prefix, then drains and claims the queues. Half of the campaigns create 71 requests
before the first repayment, crossing both the 32-request settlement limit and the
64-cohort source-accounting limit. Seeds and depths are configurable; a failing trace
is saved under `.stateful/trace-<seed>.jsonl` or `.stateful/market-<seed>.jsonl`. Run a single seed with `--count 1`;
each invocation accepts up to eight seeds. A completion marker rejects interrupted
traces, and `coverage.json` and `market-coverage.json` record successful actions, revert classes and exercised
queue/batch/claim boundaries. Required boundary cases must actually execute.
`check-runtime.py` includes the default campaigns and their Lean replay.

The checked corpus contains 32 campaigns and 15,216 recorded steps per branch, including
10,241 vault calls, 605 Harvester/fee-controller calls and 4,370 environment actions. The longest
sequence has 720 steps. The same corpus passes on the original and allowance-fixed Solidity;
the fixed branch rejects one additional `transferFrom` call with `InexactShares` (baseline seed 9, step 596).

| fixture | seeds | random depth | recorded steps | expected reverts |
| --- | --- | --- | --- | --- |
| baseline | 1–8 | 192 | 2,419 | 596 |
| baseline | 9–16 | 512 | 5,005 | 1,640 original / 1,641 allowance-fixed |
| market | 1–8 | 192 | 2,598 | 463 |
| market | 9–16 | 512 | 5,194 | 1,034 |

All campaigns pass coverage gates and 304 corrupted-output checks per branch. Incomplete traces
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

## fixture boundary

Both environments use 18-decimal mock tokens, 75% collateral LTV, 98% synthetic LT, exact token
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

the corpus stays below rescale thresholds and checks `unitScale == 0`. separate controlled
public-call fixtures reach `unitScale == 64` with ordinary holders and a waiting request, and
cumulative `unitScale == 256` with a stale account. ceil-shifted indices keep aggregate claims
within `totalUnits` and remain defined at the four-shift boundary.

separate integration checks cover three other fixture boundaries. `LeanScaledDebt.t.sol` runs 516
mint, burn and index steps against Aave core v3's actual `VariableDebtToken` 1.19.3, with a mock
Pool that drives the normalized index, and Lean replays every scaled balance and expected revert.
`SharedFlowHarness.t.sol` runs repeated harvests for two real vault instances sharing one SubLoop
and Harvester. its ICE sequence uses the actual SubLoop with `MockIntentDispatch` through entry,
expiry, permissionless reconciliation, exit, a missed callback, a late callback and final pull.

the deployed Aave Pool and reserve lifecycle, live pallet/solver execution, malicious tokens,
reentrancy, arbitrary oracle/configuration changes and the full uint256 input space remain outside
these fixtures. the integration checks are bounded executable comparisons, not live-chain tests.

This is differential execution evidence for the exercised public control flow. The machine
reuses proved arithmetic transitions, but its correspondence to arbitrary Solidity executions
is not a kernel proof or compiled-bytecode equivalence result.
