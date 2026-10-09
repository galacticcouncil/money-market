# stateful public-call comparisons

`PublicCalls.lean` composes the existing integer allocation, account, exit, Main-debt,
source-batch and redemption models into an executable public-call machine.
`LeanStatefulParity.t.sol` runs the actual vault, accounting, Main and delegatecall logic
from deployment. `StatefulReplay.lean` replays the recorded actions and compares every
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
```

The default runs eight campaigns with 192 pseudorandom actions after a deterministic
prefix, then drains and claims the queues. Half of the campaigns create 71 requests
before the first repayment, crossing both the 32-request settlement limit and the
64-cohort source-accounting limit. Seeds and depths are configurable; a failing trace
is saved under `.stateful/trace-<seed>.jsonl`. Run a single seed with `--count 1`;
each invocation accepts up to eight seeds. A completion marker rejects interrupted
traces, and `coverage.json` records successful actions, revert classes and exercised
queue/batch/claim boundaries. Required boundary cases must actually execute.
`check-runtime.py` includes the default campaigns and their Lean replay.

The default seeds 1–8 pass 2,419 calls and 596 expected reverts. Seeds 9–16 with
`--depth 512` pass another 5,005 calls and 1,640 expected reverts, with sequences up
to 696 calls. Both runs pass their coverage gates and 48 corrupted-output checks
each. An incomplete trace is also rejected. Longer standalone campaigns use a
higher test gas budget for snapshot instrumentation; this is not a gas estimate
for the public vault calls.

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

## fixture boundary

The closed environment uses the existing `MockPool`, `MockERC20` and `MockYieldSource`:
18-decimal assets at a fixed one-dollar price, 75% collateral LTV, 98% synthetic LT,
exact token transfers, fixed debt index, zero protocol fees and zero source execution
cost. Four public actors receive fixed collateral funding. The mock source custodies
HOLLAR at par; source release and pool repayment can be limited independently.
Minting HOLLAR for an outside repayment represents explicitly funded recovery, not
yield or profit. Time advances and mock liquidity controls are recorded actions too.

The corpus deliberately stays below rescale thresholds and checks `unitScale == 0`.
Rescale reachability/impact is a separate investigation. Price-driven deleveraging is
outside this fixture machine; reaching that branch fails replay instead of silently
skipping it. Harvests, nonzero fees/costs, interest accrual, debt-index rounding, external
protocol behavior and reentrancy require other fixtures and retain their existing
proof/test boundaries. The bounded trace inputs do not replace the separate checked
uint256 arithmetic tests.

This is differential execution evidence for the exercised public control flow. The
new machine reuses proved arithmetic transitions, but its correspondence to arbitrary
Solidity executions is not a kernel proof or compiled-bytecode equivalence result.
