# current Solidity mapping

reviewed against the allowance fix based on `juicer-next` at
`6bf81febcbdca15479ce44aeaaa03cec3eb5f558`, 9 october 2026.
accounting rejects unrepresentable funded debits and preserves the requested allowance
bound; [rounding evidence](ROUNDING.md) records the remaining recipient display rounding.
`solidity-manifest.json` pins source/model inputs and the OpenZeppelin math implementation.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle` | 48 epoch, cap and shift cases |
| lazy account histories | `LazyLedger`, `normalizeAccount`, `normalizeLedger` | finite trace bounds, exact account-view/settlement/scale normalization; seeded rescale counterexample |
| deposit, transfer, waiting request, start and claim lifecycle | `Lifecycle`, `exitOwner`, `exitBurned` | reachable share partition and liability bounds; exact runtime exit normalization; public vault lifecycle regression |
| `settle` / `_take` | `Runtime.take`, `fundedOf` | exact sender debit, full/fine-unit availability, conservation and 86 success/revert cases |
| `_allocate` | `Runtime.allocate`, `rescale` | 48 cases: virtual +1, fees, capital gifts, self-compounding, write-off and rescale |
| `startExit` | `Runtime.startExit` | 64 request epoch, committed unit, accrual, fee rounding and funded fold cases |
| `requiredSourceBacking` | `Runtime.requiredBacking` | 48 cash, interest and fee cases, including 100% fee |
| `splitHarvest` | `Runtime.splitHarvest` | 32 rounding, service fee and harvest reset cases |
| `SubLoopStorage` views; `SubLoopLogic.deLever` | `Runtime.outcome`, `inFlight`, `effectiveAccount`, `totalEquity`, `deLeverTarget` | 80 arrival, USD8, unflagged collateral, reserved cash, zero debt and target cases |
| `SubLoopLogic.execute` | `Runtime.callback` | 64 caller/owner, nonce, kind, output token and minimum cases |

| Main borrowing, cohort exit split and repayment | `mainBorrow`, `mainExit`, `mainRepay` | cash/unit isolation proofs; 48 public-call sequences |
| frozen source cash/cost batches | `batchSegment`, `batchCashTrace`, `batchCostTrace` | full-list telescoping conservation and no overcredit; 48 two-cohort comparisons; existing 64-item batch regression |
| source/cash bookkeeping and resumed batches | `SourceClaims`, `CashBook`, `SourceBatch` | partitions from genesis, frozen cursor/window, 64-item bound, late receipts retained; 12 multi-call comparisons |
| scaled-debt repayment retry | `retryAmount`, `checkedRetry` | remaining-cash bound, no retry for partial payment, two-observation error bound; 32 comparisons |
| vested source fees | `vestFee`, `settleFee` | junior fee bounds, cost reduction, no early charge; 48 comparisons |
| protocol reserve | `reserveDraw`, `spendable`, `repaymentLimit` | no active/unfinished draw, amount caps and protected fee cash; existing reserve regressions |
| controller credit, pacing, expiry and safety lanes | `Policy`, `available`, `policyCharge`, `executionMinimum` | credit/size bounds, no refill on refresh, quote only tightens oracle floor; 64 availability and 32 executed quote comparisons |
| FIFO start and collateral claims | `queueReady`, `startQueue`, `settleRedemption`, `claimRedemption` | work/FIFO bounds, full final burn, recipient protection; 32 queue and 48 claim comparisons |
| repeated settlement/claim histories | `RedemptionState.valid`, `settleQueue` | cumulative collateral/burn bounds, unpaid-head stop, final payout/burn; 24 three-claim histories |
| stateful public vault/Main sequences | `PublicCalls.State`, `runCall`, `execute` | independent replay from fixture genesis; exact outcomes, holder/request/Main snapshots, rollback and accounting partitions |
| checked arithmetic and failure | `Checked`, checked account/backing/borrow/batch/claim/rescale operations | success refinement, exact arithmetic revert classes, atomic failure semantics; 488 primitive, 40 account and eight backing comparisons |
| external observations | `payValid`, `exactReceipt`, `exactPayment`, callback/arrival theorems | conditional cash/debt bounds; detection threshold does not authenticate token origin |

## integer properties

`Rounding.lean` bounds floor/ceiling error, embeds mul-div in real arithmetic, and proves the
funded debit/credit bounds. `YieldTransitions.lean` proves the actual executable allocation model
keeps source and protocol reserves junior to Main backing, loss trimming respects available
capital, rescaling leaves the fund's assets intact, and exit and harvest splits conserve assets.
Finite-holder indexed accrual cannot assign more than the minted units. The `Ownership.Step`
projection preserves its unit bound for already-settled cohorts. `LazyOwnership.lean` separately
handles lazy finite-holder traces: allocations, settlements, changes in wallet weight after
settlement, new holders, unit transfers, burns, rescales and write-offs. Allocations require the
tracked weights to sum to at most the outside supply. The model is proved for any positive index
precision; `LazyRefinement.lean` instantiates it at the contract's `RAY` and proves normalization
of account views, settlement, weight changes, epoch invalidation and accumulated shifts.

For current index `I`, precision `R`, stored units/index/weight `(u, p, w)`, and ghost rounding
budget `E`, the invariant is `sum(u * R + w * (I - p)) <= total * R + E`. The budget starts at zero;
ordinary operations leave it unchanged. A rescale by `d = 2^k`, with total tracked weight `W`, uses:

```
E' = floor(((total mod d) * R + E + W * (d - 1)) / d)
```

Thus aggregate unit claims are at most `total + floor(E / R)`. For funded shares `F` and positive
total units, aggregate displayed funded claims are at most
`F + floor(F * floor(E / R) / total)`. In particular, they do not exceed `F` when the last numerator
is smaller than `total`. Without rescaling, the zero-budget trace from genesis cannot overclaim
units. These are bounds, not equality with the ideal real-number model.

`runtime_rescale_unit_excess` proves that one executable allocation can produce an aggregate unit
excess of one from an initially valid seeded state. `LeanLazyHistoryParity.t.sol` reproduces the
same state through the actual allocation and settlement functions. This test seeds storage and
uses a fixture vault; it does not establish public-call reachability or economic loss. See
`ROUNDING.md` for the exact state.

`Lifecycle.lean` includes ordinary holders and waiting requests as disjoint liability slots.
A waiting slot contains the request's committed units, prior index and escrowed wallet weight.
The invariant also tracks funded shares, started/queued shares and unsolicited shares parked in
the vault. Their sum equals ERC20 supply, so tracked weights are bounded by the actual outside
supply; this premise is derived from genesis and preserved by the lifecycle transitions.
Request creation moves committed units and weight into a fresh slot. Start merges pending
accrual into the owner, removes the request, burns its committed/exiting units and folds funded
shares into the queue. `LifecycleRefinement.lean` proves these exit quantities exactly match
`Runtime.startExit`, including epoch invalidation and accumulated shifts. Successful `take`
results establish the committed-unit bound. The repeated-claim invariant derives the burn's
availability from the started-request share partition. Rescale rounding budgets include
waiting-request weights as well as ordinary holders.

`MainHistories.lean` derives source outstanding from active and exit claims through creation,
bounded credits and advancement past zero heads. It derives owned cash from cohort cash plus
unallocated receipts through funding, assignment, repayment/fees, reserve draws and returns.
`Orchestration.lean` models a frozen source batch's remaining weights, cursor and tail. Calls
consume at most 64 exits after the initial active-cohort allocation; splitting work across calls
is equivalent to continuing the same batch. Later cash/cost receipts and later claims cannot
change its frozen proportions. Completed batches allocate exactly their original cash/cost;
later receipts remain unallocated for the next batch. The batch budget comes from the reachable
source partition and the contract's receipt guard.

The repayment retry uses observed cash paid and debt reduced separately; `payValid` states the
external observation checks. A liquidity-limited partial payment cannot trigger the retry.
The second request is bounded by the cohort's remaining spendable cash. Two accepted payments
conserve cash and have total cash/debt discrepancy at most twice the rounding quantum.
`QueueHistories.lean` preserves collateral entitlement and cumulative share-burn bounds through
arbitrary finite settlement/claim histories, including an initially debt-free exit. Its bounded
FIFO settlement stops at an unpaid head and leaves the tail untouched. Final positive claims
pay the entire fixed collateral entitlement and burn all remaining request shares.

`Checked.lean` distinguishes checked add/multiply/subtract, division, 512-bit `mulDiv`, rounded-up
`mulDiv`, shifts and atomic commit/revert. It preserves the pinned library's `ceilDiv(0, 0) = 0`
and distinct zero-denominator/large-product revert paths. `CheckedRefinement.lean` proves that
successful account views, backing gross-up, Main borrow, source batch arithmetic, claims,
rescale and write-off refine their natural-number models. Overflow in an intermediate addition
is checked before a later `min` cap. The four-shift termination bound applies to every successful
checked rescale from a uint256 total. Failed transaction bodies retain their complete pre-state
in the model; Solidity regressions also verify rollback after checkpoint, token receipt, claim
and borrow writes would otherwise have occurred.

- `RescaleAmplification.t.sol` / `RescaleReachability.t.sol` / `RescaleEconomics.t.sol` /
  `RescaleFeasibility.t.sol` investigate the seeded lazy-rescale unit excess from
  `LeanLazyHistoryParityTest`: per-rescale envelope, public-call approach, asset-level impact
  and storage preconditions. they seed accounting storage or drive public vault calls and are
  not included in the comparison-vector counts.

`LeanCoverageParity.t.sol` calls actual Main/controller/claim implementations. Main sequences
enter through vault-authorized public methods; claim and availability cases use inherited
harnesses to seed their state. Pool, source and fee-sink behavior is supplied by fixtures.
`LeanRoundingReachability.t.sol` checks the allowance fix, representable amounts, full exits
and self-transfers through public vault operations, without seeding accounting storage. The model
comparison cases are not reachability proofs for every seeded state.

`LeanRuntimeParity.t.sol` executes the actual accounting contract and inherited SubLoop logic.
External vault, price, token and pool dependencies are fixtures. Expectations come from executing
Lean. Private seed slots are checked against the compiler's storage layout before tests run.

`LeanLifecycleParity.t.sol` runs deposits, yield allocation, transfers, donations, multiple waiting
requests, sequential starts and partial/final claims through the actual vault. It reads private
units to check the complete numerator invariant; it does not seed accounting storage or impersonate
the vault. The pool/source returns still come from fixtures. `LeanMachineParity.t.sol` checks actual
Main retry/batch calls, math primitives, account/backing boundaries and rollback. Its account
boundary cases seed storage. Its repeated-claim harness supplies settlement observations while
retaining the previous claims' real storage and token transfers; the public lifecycle separately
exercises `pokeSettle` itself. These tests are implementation comparisons, not reachability proofs
for every machine-boundary fixture.

`LeanStatefulParity.t.sol` adds long public-call campaigns against the actual vault, accounting,
Main and delegatecall logic, using the existing deterministic pool/token/source mocks.
`StatefulReplay.lean` keeps its own predicted state from fixture genesis; it never resets from
a Solidity snapshot. Each call checks its outcome, all tracked holder/allowance/request/Main
fields, and share, cash, collateral and lazy-liability partitions. The default eight seeds cover
2,419 recorded steps, including 596 expected reverts and 48 deliberately corrupted outputs rejected by
the checker. Coverage gates require partial/final claims, keeper receiver protection, 71-request
starts, resumed 64-cohort batches with late receipts and the 32-request settlement limit.
Eight additional seeds with 512 pseudorandom actions pass 5,005 recorded steps and 1,640 expected reverts;
the longest complete sequence has 696 steps. Together the 16 campaigns check 7,424 recorded steps,
2,236 expected reverts and 96 corrupted-output checks. A truncated-trace rejection also passes.
See [stateful scope and reproduction](STATEFUL_PARITY.md). These tests exercise control-flow
correspondence for a bounded fixture environment, not every Solidity trace.

## corrections

- Minting is `ceil(debt * 10000 / lt) + floor(base / 200)`. The old floored mint formula and
  196-wei precondition were removed; the floor now holds for every debt with positive LT.
- The synthetic reserve has 100 bps LTV. The vault excludes it from its own borrowing budget.
  Solidity's separate `noSynthBorrow` invariant checks zero synthetic-token debt, a different property.
- Runtime ICE HF nets waiting ENTRY HOLLAR against debt and restores EXIT aPRIME to collateral.
  Idle cash counts in equity, not that HF adjustment. The older `IceLoop.grossHF` (formerly
  `effHF`) and `oracleSaleOk` are explicitly abstract algebra, not the runtime HF/trigger.
- Runtime arrival detection uses balance deltas of at least half the expected amount. Authenticated
  callbacks instead check the output token and minimum. The ideal pallet-outcome book abstracts this.
- Real-valued yield theorems omit rounding, virtual units, epochs and lazy shifts. The integer
  layer includes them. Successful funded transfers now debit exactly the requested displayed
  amount or revert. With the recipient unit cap inactive, its credit can differ by one base unit.
  `take_rounding_example` checks rejection of the old counterexample, and `take_fine_available`
  proves fine-unit liveness.
- `freedBacked` is a solvency hypothesis, not an on-chain deposit gate. `collSold` is a hypothetical
  shortfall diagnostic; current collateral claims remain owed during underfunding.

## verification

527 source theorem/lemma declarations compile, including declarations with same-line attributes.
The axiom audit checks all 1,091 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. This adds 100 source declarations to the previous coverage. The comparison datasets
contain 1,430 rows: the previous 826 plus 604 machine-boundary and history cases. Validation also
includes 512 transfer rounding fuzz cases, the public vault lifecycle, rollback regressions and the
existing seeded lazy-rescale fixture. All three generated datasets reproduce exactly.
The full formal check passes 64 Lean-prefixed Foundry tests with zero failures and skips, including inherited
fixture regressions; the rescale suites add 18 test executions (three inherited harvest tests)
and 256 fuzz cases. source fingerprints and storage-layout checks also pass.
The prior allowance-fix run also passed 187 distinct targeted tests. Production Solidity is
unchanged by this proof merge; the prior London build measured CollateralVault at 24,480 bytes
and JuicerYieldAccounting at 12,513 bytes (117 bytes larger than the original branch).

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

This builds the proofs, regenerates and compares 1,430 cases across three datasets, checks source
fingerprints and storage slots, then runs the comparison suites, 512 transfer rounding fuzz cases,
the public-call allowance regressions and the seeded lazy-rescale case. After a reviewed model
change, regenerate with:

```sh
lake build
lake env lean --run ParityVectors.lean > runtime-vectors.json
lake env lean --run CoverageVectors.lean > coverage-vectors.json
lake env lean --run MachineVectors.lean > machine-vectors.json
```

Update the manifest after reviewing corresponding source/model changes. Fingerprints detect drift;
they are not correctness proofs. `--compiled` uses previously compiled modules from `LEAN_PATH`
for isolated verification.

## proof boundary

The natural-number layer describes successful arithmetic. The checked layer adds uint256 failure
semantics for the operations listed above, with ABI/storage inputs in range. It is a functional
specification of Solidity arithmetic and the pinned math library, not a proof of the library's
assembly implementation. Valid configuration and truthful external observations remain premises.
Four 64-bit rescale steps suffice for an initial total below `2^256`; checked scale/epoch counter
overflow reverts rather than silently wrapping.

The 1,430 cases are cross-language comparisons, not a proof of every Solidity trace. The lifecycle
and Main transition systems derive their numerical partitions from genesis and cover the listed
call sequences. Mapping Solidity storage identities, call dispatch and every guard to those
transition systems is still manual. Liability slots must represent distinct holders or disjoint
waiting requests; all liabilities must be included in the initial representation. The new genesis
results remove the repeated numerical weight/partition assumptions, not that representation boundary.
The real-valued index proofs remain ideal arithmetic; exact integer equivalence would contradict
the checked rescale counterexample.
Main arithmetic, fee vesting, controller policies, source orchestration, retries and queue histories
have the coverage above. Cross-contract control-flow equivalence, arithmetic outside the listed
checked operations, upgrades and reentrancy remain outside the kernel proof. Access control and
trusted administrative configuration are not replaced
by the arithmetic models. Protocol fee-controller binding/custody and live Aave scaled accounting
remain regression/fixture boundaries rather than formalized external protocol implementations.

Aave/token observations must be truthful, oracle prices/configuration valid, and external calls
successful where their results are model inputs. Matching ICE's half-minimum arrival heuristic
does not prove an arrival came from the intended solver; it also does not imply that the stricter
minimum required by an authenticated callback was received. Keeper/solver liveness, bounded market
losses and solvency cannot be derived from these arithmetic results. No deployed bytecode or
live-chain state was checked in this update.

The [older Verity bridge](bridge/PARITY.md) remains a simplified reference model. Neither its two
mock tests nor these comparisons establish deployed-bytecode equivalence or a live-Aave run.
