# current Solidity mapping

reviewed against `juicer-allowance-rounding` at
`33bfd25e662a3859ce12728dc455389cbd89d62b`, 10 october 2026.
accounting rejects unrepresentable funded debits and preserves the requested allowance
bound; [rounding evidence](ROUNDING.md) records the remaining recipient display rounding.
the common formal update is based on `juicer-next` at
`21f5aa7b203d0ae79f44e05c87ed75f8d242a1ef`.
`solidity-manifest.json` pins source/model inputs, integration fixtures and the math implementations;
the check fails if they change without a new comparison.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle` | 48 epoch, cap and shift cases |
| lazy account histories | `LazyLedger`, `normalizeAccount`, `normalizeLedger`, `BoundedStep` | finite trace bounds, exact account-view/settlement/scale normalization, uniform bounded-rescale slack; seeded excess witness and public-call rescale reachability |
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
| Aave scaled balances | `ScaledDebt`, `rayMulHalf`, `rayDivHalf` | 516 calls against Aave core v3 `VariableDebtToken` 1.19.3; exact scaled/user/total balances and 43 expected reverts |
| vested source fees | `vestFee`, `settleFee` | junior fee bounds, cost reduction, no early charge; 48 comparisons |
| protocol reserve | `reserveDraw`, `spendable`, `repaymentLimit` | no active/unfinished draw, amount caps and protected fee cash; existing reserve regressions |
| controller credit, pacing, expiry and safety lanes | `Policy`, `available`, `policyCharge`, `executionMinimum` | credit/size bounds, no refill on refresh, quote only tightens oracle floor; 64 availability and 32 executed quote comparisons |
| FIFO start and collateral claims | `queueReady`, `startQueue`, `settleRedemption`, `claimRedemption` | work/FIFO bounds, full final burn, recipient protection; 32 queue and 48 claim comparisons |
| repeated settlement/claim histories | `RedemptionState.valid`, `settleQueue` | cumulative collateral/burn bounds, unpaid-head stop, final payout/burn; 24 three-claim histories |
| stateful vault/Main/harvest sequences | `PublicCalls.State`, `runCall`, `execute`, `CertifiedCalls` | independent replay from fixture genesis; exact outcomes, holder/request/Main snapshots and rollback; kernel-checked collateral conservation across certified call histories |
| shared-loop harvest and ICE histories | lifecycle and runtime projections | repeated harvests across two vaults sharing one loop; long actual-SubLoop intent expiry/reconcile/late-callback/exit sequence |
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

`RescaleBounds.lean` strengthens the one-step recurrence to
`E' <= ((total mod 2^k) * R + E) / 2^k + W`. for histories whose positive-shift rescale steps
have `W <= cap`, it proves the uniform bound `E <= 2 * (R + cap)` from genesis, carries that bound
through ordinary steps and write-offs, and derives aggregate funded-claim bounds. with `cap <= R`,
`funded * 4 < total` is a sufficient no-overclaim condition. a separate allocation theorem shows
that any one-step 64-bit rescale trigger leaves shifted total plus newly minted units at least
`2^96` under the modeled allocation formula.

`runtime_rescale_unit_excess` proves that one executable allocation can produce an aggregate unit
excess of one from an initially valid seeded state. `LeanLazyHistoryParity.t.sol` reproduces the
same state through the actual allocation and settlement functions. that test seeds storage.
`LeanRescalePublic.t.sol` separately reaches a 64-bit rescale through vault deposits, SubLoop
ramping and repeated `sync` calls in a controlled mock-value environment. three ordinary public
holders end two units below `totalUnits`; the seeded excess is not reproduced. neither fixture
establishes an economically feasible deployed-market loss. see `ROUNDING.md` for the exact boundary.

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

`PublicInvariants.lean` proves custody conservation for checkpointing, Main payment and batch
credit, reserve cover, settlement records and bounded settlement loops. `CustodyStep` composes
those cases with deposits, claims and supply-to-liquid movement; `CertifiedCalls` carries the
invariant through arbitrary lists of actual `execute` results, and failed calls automatically
produce frame steps because `execute` rolls back. successful dispatch branches still require the
corresponding `CustodyStep` certificate. source-claim, cash-book and lifecycle projections connect
public states to the existing arbitrary-history partition and lazy-liability theorems; deriving
those projection traces from every successful `runCall` branch remains a manual mapping boundary.

`LeanStatefulParity.t.sol` adds long public-call campaigns against the actual vault, accounting,
Main and delegatecall logic, using the existing deterministic pool/token/source mocks.
`StatefulReplay.lean` keeps its own predicted state from fixture genesis; it never resets from
a Solidity snapshot. Each call checks its outcome, all tracked holder/allowance/request/Main
fields, and share, cash, collateral and lazy-liability partitions. The default eight seeds cover
2,419 recorded steps, including 596 expected reverts and 48 deliberately corrupted outputs rejected by
the checker. Coverage gates require partial/final claims, keeper receiver protection, 71-request
starts, resumed 64-cohort batches with late receipts and the 32-request settlement limit.
Eight additional seeds with 512 pseudorandom actions pass 5,005 recorded steps and 1,641 expected reverts;
the longest baseline sequence has 696 steps. Together the 16 campaigns check 7,424 recorded steps,
2,237 expected reverts and 96 corrupted-output checks. A truncated-trace rejection also passes.
`LeanMarketStatefulParity.t.sol` adds the actual Harvester and fee controller with changing source
values, collateral prices, debt observations and execution costs. Its default eight campaigns pass
2,598 recorded steps, 463 expected reverts and 104 corrupted-output checks. Coverage gates require
harvests/reward mints, fee collection, interest servicing, debt-rounding retries, peg top-ups,
source costs/losses and completed price-driven deleveraging. Both fixtures run in the formal check.
The larger market campaigns add 5,194 steps and 1,034 expected reverts, reaching 720 steps per
sequence. Across both fixtures, 32 campaigns pass 15,216 recorded steps and 304 corruption checks.
See [stateful scope and reproduction](STATEFUL_PARITY.md). These tests exercise control-flow
correspondence for a bounded fixture environment, not every Solidity trace.

`LeanScaledDebt.t.sol` imports Aave core v3's actual `VariableDebtToken` 1.19.3 and drives it from
a mock Pool through 516 deterministic mint, burn and monotonically increasing index calls. Lean
independently replays Aave's half-up ray division/multiplication and compares scaled balances,
displayed balances, total supply and each user's previous index after every call. the comparison
includes 43 expected reverts and four complete repayments. it checks the token implementation;
the Pool, reserve configuration and index evolution are controlled inputs.

`SharedFlowHarness.t.sol` adds two bounded integration histories. one repeatedly harvests through
the actual Harvester for two vaults sharing one SubLoop and checks the registered-share partition,
asset isolation and funded balances. the other drives the actual SubLoop through ICE entry,
expiry, reconciliation, exit, a missed callback, a late callback and final pull with
`MockIntentDispatch`. these are executable integration checks rather than Lean state-by-state
replays.

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

563 source theorem/lemma declarations compile, including declarations with same-line attributes.
the axiom audit checks all 1,154 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. the public-call machine includes rollback and certified-history custody theorems;
its complete Solidity dispatch correspondence is tested by replay, not proved for all executions.
the comparison datasets contain 1,430 rows: the previous 826 plus 604 machine-boundary and history
cases. validation also includes 512 transfer-rounding fuzz cases, the public vault lifecycle,
rollback regressions, all four focused rescale suites, and the seeded and public-call rescale
fixtures. all three generated datasets reproduce exactly.
the Aave scaled-debt trace adds 516 calls with 43 expected reverts. the full formal check invokes
99 Foundry tests with zero failures and skips, including inherited fixture regressions and the two
targeted shared-flow histories; source fingerprints, all 17 accounting slots and the six private
Main batch slots also pass. the legacy environment-gated Verity fork suite is outside this formal gate.
the prior allowance-fix run also passed 187 distinct targeted tests. production Solidity is
unchanged by this proof merge; the prior London build measured CollateralVault at 24,480 bytes
and JuicerYieldAccounting at 12,513 bytes (117 bytes larger than the original branch).

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

this builds the proofs, regenerates and compares 1,430 cases across three datasets, checks source
fingerprints and storage slots, then runs the comparison suites, 512 transfer-bound fuzz cases,
the allowance, rounding and rescale reproductions, the 516-call Aave scaled-debt replay and both
shared-flow histories. after a reviewed model change, regenerate with:

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

the 1,430 vector cases and 516 scaled-debt calls are cross-language comparisons, not a proof of
every Solidity trace. the lifecycle and Main transition systems derive their numerical partitions
from genesis and cover the listed call sequences. public-call custody is kernel-checked for
certified `execute` histories, while mapping every successful dispatch branch to a certificate and
to the source/cash/lifecycle transition systems is still manual. liability slots must represent
distinct holders or disjoint
waiting requests; all liabilities must be included in the initial representation. The new genesis
results remove the repeated numerical weight/partition assumptions, not that representation boundary.
The real-valued index proofs remain ideal arithmetic; exact integer equivalence would contradict
the checked rescale counterexample.
Main arithmetic, fee vesting, controller policies, source orchestration, retries and queue histories
have the coverage above. Cross-contract control-flow equivalence, arithmetic outside the listed
checked operations, upgrades and reentrancy remain outside the kernel proof. Access control and
trusted administrative configuration are not replaced
by the arithmetic models. protocol fee-controller binding/custody and the deployed Aave Pool remain
fixture boundaries rather than formalized external protocol implementations. the scaled-debt model
matches the pinned token history but does not prove Aave's assembly or arbitrary Pool behavior.

Aave/token observations must be truthful, oracle prices/configuration valid, and external calls
successful where their results are model inputs. Matching ICE's half-minimum arrival heuristic
does not prove an arrival came from the intended solver; it also does not imply that the stricter
minimum required by an authenticated callback was received. Keeper/solver liveness, bounded market
losses and solvency cannot be derived from these arithmetic results. No deployed bytecode or
live-chain state was checked in this update.

The [older Verity bridge](bridge/PARITY.md) remains a simplified reference model. Neither its two
mock tests nor these comparisons establish deployed-bytecode equivalence or a live-Aave run.
