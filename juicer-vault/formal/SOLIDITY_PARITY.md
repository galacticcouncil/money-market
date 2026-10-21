# current Solidity mapping

reviewed in the PR #79 `juicer-pr46-fixes` working tree on 13 october 2026.
the manifests below pin the exact source and artifact inputs.
accounting rejects unrepresentable funded debits and preserves the requested allowance
bound; [rounding evidence](ROUNDING.md) records the remaining recipient display rounding.
the common formal update is based on `juicer-next` at
`21f5aa7b203d0ae79f44e05c87ed75f8d242a1ef`.
`solidity-manifest.json` pins source/model inputs, integration fixtures and the math implementations.
`bytecode-manifest.json` pins creation bytecode, runtime templates, compiler settings, immutable/link
references and method ids for 11 production contracts; the checks fail if either layer drifts.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle`, `ceilShift` | 48 epoch, cap and shift cases; seeded scale-256 regressions and public no-rescale recovery histories |
| lazy account histories | `LazyLedger`, `normalizeAccount`, `normalizeLedger` | finite trace bounds, corrected ceil-shift normalization, aggregate unit and funded no-overclaim from genesis |
| deposit, transfer, waiting request, start and claim lifecycle | `Lifecycle`, `exitOwner`, `exitBurned` | reachable share partition and liability bounds; exact runtime exit normalization; public vault lifecycle regression |
| `settle` / `_take` | `Runtime.take`, `fundedOf` | exact sender debit, full/fine-unit availability, conservation and 86 success/revert cases |
| `_allocate` | `Runtime.allocate`, `trimLoss`, `restoreLoss`, `rescale`, `allocationMinted` | first allocation prices the whole fund; virtual +1, fees, capital gifts, loss-carry restoration before new weight, self-compounding, write-off and rescale |
| `startExit` | `Runtime.startExit` | 64 request epoch, committed unit, accrual, fee rounding and funded fold cases; seeded waiting-request rescale regression |
| `requiredSourceBacking` | `Runtime.requiredBacking` | 48 cash, interest and fee cases, including 100% fee |
| `splitHarvest` | `Runtime.splitHarvest` | 32 rounding, service fee and harvest reset cases |
| `SubLoopStorage` views; `SubLoopLogic.deLever` | `Runtime.outcome`, `inFlight`, `effectiveAccount`, `totalEquity`, `deLeverTarget` | 80 cases: 99% arrival boundaries, USD8, foreign collateral dust, available unwind cash, zero debt and targets |
| unwind and safety sale sizing | `Runtime.unwindNeed`, `deleverNeed`, `stepHfFloor` | 64 idle-cash, insolvent, dust, slippage, lane-minimum and floor comparisons |
| `SubLoopLogic.execute` | `Runtime.callback` | 64 caller/owner, nonce, kind, output token and minimum cases |

| Main borrowing, cohort exit split and repayment | `mainBorrow`, `mainExit`, `mainRepay` | cash/unit isolation proofs; 48 public-call sequences |
| frozen source cash/cost batches | `batchSegment`, `batchCashTrace`, `batchCostTrace` | full-list telescoping conservation and no overcredit; 48 two-cohort comparisons; existing 64-item batch regression |
| source/cash bookkeeping and resumed batches | `SourceClaims`, `CashBook`, `SourceBatch` | partitions from genesis, frozen cursor/window, 64-item bound, late receipts retained; 12 multi-call comparisons |
| scaled-debt repayment retry | `retryAmount`, `checkedRetry` | remaining-cash bound, no retry for partial payment, two-observation error bound; 32 comparisons |
| Aave scaled balances | `ScaledDebt`, `rayMulHalf`, `rayDivHalf` | 516 calls against Aave core v3 `VariableDebtToken` 1.19.3; exact scaled/user/total balances and 43 expected reverts |
| vested source fees | `vestFee`, `settleFee` | junior fee bounds, cost reduction, no early charge; 48 comparisons |
| protocol reserve | `reserveDraw`, `spendable`, `repaymentLimit` | no active/unfinished draw, amount caps and protected fee cash; existing reserve regressions |
| controller credit, pacing, expiry and safety lanes | `Policy`, `available`, `policyCharge`, `executionMinimum`, `pacingNextAt` | credit/size bounds, no refill on refresh, quote only tightens oracle floor; 64 availability, 32 executed quote and 32 proportional-pacing comparisons, including uint64 casts |
| FIFO start and collateral claims | `queueReady`, `startQueue`, `settleRedemption`, `claimRedemption` | work/FIFO bounds, full final burn, recipient protection; 32 queue and 48 claim comparisons |
| repeated settlement/claim histories | `RedemptionState.valid`, `settleQueue` | cumulative collateral/burn bounds, unpaid-head stop, final payout/burn; 24 three-claim histories; zero-share, debt-free empty requests advance both cursors |
| stateful vault/Main/harvest/loss-recovery sequences | `PublicCalls.State`, `SolidityDispatch`, `ValidSolidityTrace`, `PublicInvariant` | complete source-checked 31-opcode fixture map; arbitrary finite certified raw-trace preservation; independent replay from fixture genesis with exact outcomes, snapshots and rollback |
| shared-loop harvest and ICE histories | lifecycle and runtime projections | repeated harvests across two vaults sharing one loop; long actual-SubLoop intent expiry/reconcile/late-callback/exit sequence |
| shared intent/harvest accounting | `SharedIntent.State`, `SharedIntent.call`, `SharedIntent.snapshot` | 1,176 calls against production SubLoop and Harvester: two-vault fills, refunds, gifts, rebases, cost checkpoints and reconcile-before-weight ordering |
| audit liveness and loss allocation | `AuditProgress`, `AuditLossAllocation` | conditional arbitrary-queue progress and fragmented-pacing bounds; executable 50 bps admission, frozen pending-intent membership, owned parked gifts, loss-carry recovery and capped-cost liability boundaries |
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
ordinary operations leave it unchanged. A rescale by `d = 2^k` ceil-shifts each nonzero prior
index, clamps it to `floor(I / d)`, and uses:

```
E' = floor(((total mod d) * R + E) / d)
```

`LazyOwnership.lean` proves
`d * (floor(I / d) - min(floor(I / d), ceil(p / d))) <= I - p`, removing the former
weight-dependent slack term. `RescaleBounds.lean` proves that `E < R` remains true across every
rescale. ordinary steps preserve slack and write-off resets it, so every modeled trace from genesis
has aggregate unit claims at most `total`. for positive total units, the sum of individually
floored funded claims is also at most the fund `F`. These are integer transition bounds, not a
proof of compiled-Solidity equivalence for every call sequence.

`Rounding.lean` proves that nested ceil shifts compose and that its natural-number definition is
equal to `p == 0 ? 0 : ((p - 1) >> k) + 1`. this matches the overflow-safe Solidity helper even
at cumulative shifts of 256 or more. `Runtime.startExit` applies the same shift to waiting-request
indices.

`runtime_rescale_ceil_index_closes_excess` checks the original seeded counterexample after the
correction. `LeanLazyHistoryParity.t.sol` reproduces it through the actual allocation and
settlement functions; aggregate claims finish one unit below `totalUnits`. the separate seeded
waiting-request regression finishes exactly at `totalUnits`, and a seeded four-shift case reaches
scale 256. `LeanRescalePublic.t.sol` and the public section of `RescaleCeilIndexAudit.t.sol` now
exercise repeated partial loss and refill through real public calls: loss carry restores the
incumbent cohort, waiting requests remain valid, and `unitScale` stays zero. see `ROUNDING.md` for
the exact boundary.

the ceil shift chooses downward entitlement rounding at the rescale boundary. the original seeded
case leaves one unit unclaimed, and funded residue can remain after all represented holders exit.
`RoundingResidue.lean` tracks a second ghost budget from genesis through allocation, settlement,
movement, burn, escrow, start, repeated rescale and write-off. it bounds missing aggregate units
and the resulting funded residue for arbitrary finite histories, including waiting-request slots.
this is an aggregate lower bound; it does not assign rounding loss fairly to individual holders.

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
availability from the started-request share partition. Rescale ceil-shifting applies to waiting-request indices as well as ordinary holders.

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
`mulDiv`, floor and safe ceil shifts, and atomic commit/revert. It preserves the pinned library's `ceilDiv(0, 0) = 0`
and distinct zero-denominator/large-product revert paths. `CheckedRefinement.lean` proves that
successful account views, backing gross-up, Main borrow, source batch arithmetic, claims,
rescale and write-off refine their natural-number models. Overflow in an intermediate addition
is checked before a later `min` cap. The four-shift termination bound applies to every successful
checked rescale from a uint256 total. Failed transaction bodies retain their complete pre-state
in the model; Solidity regressions also verify rollback after checkpoint, token receipt, claim
and borrow writes would otherwise have occurred.

- `LeanLazyHistoryParity.t.sol`, `RescaleAmplification.t.sol`, `RescaleReachability.t.sol`,
  `RescaleEconomics.t.sol`, `RescaleFeasibility.t.sol`, `RescaleCeilIndexAudit.t.sol` and
  `LeanRescaleStatefulParity.t.sol` cover the
  original seeded counterexample, aggregate no-overclaim, funded-share behavior, storage
  preconditions, waiting requests, seeded cumulative scale 256 and public high-water recovery at
  scale zero. they seed accounting storage or drive controlled public vault calls and are not
  included in the comparison-vector counts.

`LeanCoverageParity.t.sol` calls actual Main/controller/claim implementations. Main sequences
enter through vault-authorized public methods; claim and availability cases use inherited
harnesses to seed their state. Pool, source and fee-sink behavior is supplied by fixtures.
`LeanRoundingReachability.t.sol` checks the allowance fix, representable amounts, full exits
and self-transfers through public vault operations, without seeding accounting storage; the
fund's donated balance is written directly because the fund rejects transfers. The model
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
invariant through arbitrary lists of hand-certified `rawExecute` results, and failed raw calls
automatically produce frame steps because `rawExecute` rolls back. `PublicCertificates.lean`
adds a decidable combined invariant over collateral custody, source claims, owned cash, lazy
lifecycle accounting and the operational array/request partitions used by the dispatcher. the
checked `runCall` preserves the raw successful result exactly when its post-state satisfies that
invariant; otherwise it returns the model-only code 98 and `execute` rolls back. consequently
`runCall_success_preserves`, `execute_preserves` and `certifiedReplay_total` cover every checked
call and every finite checked-call list from a certified input.

`SolidityDispatch.lean` gives every fixture opcode 0–30 a typed target, selector and action-argument
projection. `check-dispatch.py` checks the map against both pinned Solidity `perform` functions;
`solidity_dispatch_corresponds` and `solidity_execute_corresponds` prove that the typed map equals
the raw Lean dispatcher for every action. `PublicReachability.lean` proves 21 opcodes
preserve `PublicInvariant` from the current state alone. `PublicTransferProofs.lean` adds transfer
and transferFrom for ordinary holders and bounded destinations; `PublicClaimProofs.lean` adds
claims of started requests. `PublicMetadataProofs.lean`, `PublicAllocationProofs.lean` and
`PublicCheckpointProofs.lean` prove sync/checkpoint preservation from bounded account/request
epochs and scales, including allocation, write-off and all four rescale steps.
`PublicPaymentProofs.lean` proves Main payment preserves cash, source claims and unit totals for
every in-bounds position, including retries and cleared tails. `PublicCompoundProofs.lean`
composes cash funding, payment, reward reservation and funded-share minting, proves equality with
the original compound body, and proves opcode 24 from its pre-state invariant alone.
`PublicRequestPreparation.lean` and `PublicRequestProofs.lean` prove request append and funded-unit
splitting, then compose checkpointing, allowance spending and escrow transfers into opcode 4.
`PublicDepositProofs.lean` proves opcode 0 through Main payment, checkpointing, locked-share
initialization, receiver minting and reserve cover. its additional initialization premise requires
the reward index to be zero whenever supply is zero. a fabricated zero-supply, nonzero-index state
passes the old certificate but breaks initial minting; a kernel-checked regression excludes it.
`PublicSourceProofs.lean` and `PublicRebalanceProofs.lean` prove source-value rounding bounds,
Main unit minting, active-unwind booking and both raw rebalance branches. rebalance requires a
zero active fee remainder whenever its source remainder is zero.
`PublicSettlementProofs.lean` proves settlement records, Main payments and arbitrary-length
settlement loops preserve the invariant when aggregate owed collateral is backed by assets and
the Main position count matches the unwind cursor plus one.
`PublicCreditProofs.lean`, `PublicBatchProofs.lean` and `PublicCreditEntryProofs.lean` prove
per-position credit, fee backing, cash/cost budgets, arbitrary-length credit loops and raw
`pokeSettle`. its input premises bound source pull/cost rates, tie the saved batch cursor to the
remaining weights, and require fees to be backed by cash or remaining yield. the proof covers
fresh batches, resumed batches and receipts arriving during an unfinished batch.
`PublicHarvestProofs.lean` proves the exact raw harvest body through source withdrawal,
reward/protocol reservation release and compounding. the model caps its burn at held source
shares and consumes the proportional realized reserve slice, matching the Harvester capacity cap.
`harvestBound_all` proves the resulting capacity bound for every state.
the unwind proofs connect lazy-account consumption, source/Main splitting, rounding coverage and
request activation to the exact raw `startOne` body. `startMany_preserves` covers arbitrary loop
lengths with a proof cursor that agrees with the final stored cursor. `startUnwinds` requires
consistent metadata, queue backing, ordinary waiting owners and a fee rate at most 10000 basis points.
`ValidSolidityAction` accepts all 31 structural cases from their inputs or a raw revert. it no
longer accepts successful calls by computing their post-state certificate; `valid_success_input`
proves every admitted success has a structural input rule. replay checks metadata, initialization,
active-fee, queue-backing, credit-readiness, pull/cost-rate, harvest-capacity and unwind premises at genesis
and before and after every call, using the predicted state compared with Solidity storage.
`validSolidityTrace_invariant` and `validSolidityReachable_invariant` carry that certificate through
arbitrary finite raw traces from any certified fixture genesis. the orphan-claim regression records
the necessary boundary: a fabricated raw storage state can contain a settled claim without any
assets or liquid collateral, and raw claim dispatch would accept it, while the certified
reachability theorem excludes that input state. `PublicBoundaryRegressions.lean` also records
a fabricated future account epoch that breaks raw checkpointing and a vault-impersonation call
that removes waiting-request escrow. the former lacks a reachable metadata history; the latter
falls outside the ordinary-holder transfer premise. these are proof-boundary regressions, not
public Solidity exploit claims.

`rawReplay_metadata` proves account/request epochs and scales consistent across every raw action,
including rollback and unsupported opcodes. `rawReplay_genesis_callBounds` separately proves
source pull/cost rates and fee rates remain at most 10000 basis points, and all stored request
owners remain ordinary, across arbitrary finite fixture-call histories. `PublicReady` combines
these with initialization, active-fee, queue-backing, credit-readiness and the financial invariant.
`ordinaryTrace_fixture_ready` proves the combined certificate from each concrete replay genesis
through every arbitrary finite ordinary trace. its action domain retains the fixture bounds,
four external direct-transfer callers and the started-claim-or-revert condition, but contains
none of the accounting readiness premises.

the permissive action domain remains useful as a boundary: a ten-call trace that impersonates the
locked holder exhausts supply and leaves a nonzero reward index, so initialization is not inductive
there. a separate seven-call history proves a harvest quote can exceed held source shares by two;
the Solidity Harvester already caps that burn, and the Lean runtime now applies the same cap and
realizes only the corresponding reserve slice. another regression raises the TVL cap and attempts
to deposit one collateral unit beyond the caller's balance; the raw model now rolls back with the
fixture ERC20-balance error, matching Solidity rather than natural-number saturating subtraction.

`LeanStatefulParity.t.sol` adds long public-call campaigns against the actual vault, accounting,
Main and delegatecall logic, using the existing deterministic pool/token/source mocks.
`StatefulReplay.lean` keeps its own predicted state from fixture genesis; it never resets from
a Solidity snapshot. Each call checks its outcome, all tracked holder/allowance/request/Main
fields, and share, cash, collateral and lazy-liability partitions. The default eight seeds cover
2,419 recorded steps, including 662 expected reverts and 48 deliberately corrupted outputs rejected by
the checker. Coverage gates require partial/final claims, keeper receiver protection, 71-request
starts, resumed 64-cohort batches with late receipts and the 32-request settlement limit.
`LeanMarketStatefulParity.t.sol` adds the actual Harvester and fee controller with changing source
values, collateral prices, debt observations and execution costs. Its default eight campaigns pass
2,598 recorded steps, 495 expected reverts and 104 corrupted-output checks. Coverage gates require
harvests/reward mints, fee collection, interest servicing, debt-rounding retries, peg top-ups,
source costs/losses and completed price-driven deleveraging. Both fixtures run in the formal check.
`LeanRescaleStatefulParity.t.sol` retains its historical contract and trace name but now adds long
public loss/recovery histories with ray-scale account/request weights. every partial loss records
carry, every refill restores it before new allocation, a waiting request survives the cycles, and
the public accounting scale must remain zero. the histories then cover settlement, start, partial
and final claims, write-off, refill and funded harvest. see
[stateful scope and reproduction](STATEFUL_PARITY.md). these tests exercise control-flow body
correspondence for a bounded fixture environment; the opcode map itself is checked exhaustively.
the formal gate emits current step, revert and mutation counts from all 24 default campaigns. the
historical pre-high-water corpus and deeper runs are recorded separately in `STATEFUL_PARITY.md`.

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

`LeanSharedIntent.t.sol` and `SharedIntentReplay.lean` add that state-by-state comparison for the
shared source. the harness uses the production SubLoop, SubLoopLogic, Harvester and
ExecutionController; two callback vaults and a binding-only fee controller expose the surrounding
source-facing boundary.
Lean starts from deployment constants and independently applies deposits, entry and exit intents,
fills, refunds, unsolicited token arrivals, callbacks, reconciliation, harvests, blocked services,
cost acknowledgements and pulls. every call result and 46 base fields plus every pallet intent
are compared. delaying the initial Harvester reconciliation must change the prediction in covered
states, preventing the PR #79 ordering fix from becoming a no-op in the model.

## corrections

- Minting is `ceil(debt * 10000 / lt) + floor(base / 200)`. The old floored mint formula and
  196-wei precondition were removed; the floor now holds for every debt with positive LT.
- The synthetic reserve has 100 bps LTV. The vault excludes it from its own borrowing budget.
  Solidity's separate `noSynthBorrow` invariant checks zero synthetic-token debt, a different property.
- runtime ICE HF adds in-flight input value to collateral and leaves debt unchanged. available
  idle HOLLAR also backs collateral while an unwind target is active. with no extra backing,
  the original Aave HF is retained. the older `IceLoop.grossHF` (formerly
  `effHF`) and `oracleSaleOk` are explicitly abstract algebra, not the runtime HF/trigger.
  `effective_hf_gross_interval` connects the recomputed integer HF to `IceLoop.grossHF`:
  with positive debt, nonzero extra backing and matching gross assets/debt/LT, the runtime
  result is within one HF unit below the ideal ratio scaled by `10^18`. those matching-value
  premises include the cash eligibility and USD8 quantization boundary.
- runtime arrival detection uses balance deltas of at least `amount - amount / 100` (ceil 99%). authenticated
  callbacks instead check the output token and minimum. The ideal pallet-outcome book abstracts this.
- Real-valued yield theorems omit rounding, virtual units, epochs and lazy shifts. The integer
  layer includes them. Successful funded transfers now debit exactly the requested displayed
  amount or revert. With the recipient unit cap inactive, its credit can differ by one base unit.
  `take_rounding_example` checks rejection of the old counterexample, and `take_fine_available`
  proves fine-unit liveness.
- `freedBacked` is a solvency hypothesis, not an on-chain deposit gate. `collSold` is a hypothetical
  shortfall diagnostic; current collateral claims remain owed during underfunding.
- fund recipients are rejected before checkpoint/settlement, including wallet-only transfers and
  deposits. the first allocation with zero total units prices the whole existing fund.
- empty funded requests may fold to zero shares and start debt-free. the redemption invariant
  allows this case while preserving all payout and burn bounds. delever targets decrease by
  repayment cash spent; debt and synthetic balances still use the observed debt reduction.
- unwind sizing includes idle cash in gross backing; safety sales are capped by target need,
  subject to the controller minimum, and use the 1.005 step floor. routine exits retain 1.02.
- harvest reconciles before reading source weights. its two-vault regression and the foreign
  collateral clearing regressions run in the formal gate; external Pool behavior and the full
  shared-loop call graph remain integration-test boundaries.

## verification

1,594 source theorem/lemma declarations compile, including declarations with same-line attributes.
the axiom audit checks all 2,996 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. the public-call machine includes rollback and certified-history custody theorems;
its 31-opcode typed fixture dispatch correspondence is universally proved and source-checked.
`Solidity/BodyProofs.lean` proves the extracted solc AST of `_shiftIndex` equals
`Runtime.ceilShift` for every uint256 input pair, including arithmetic checks and shifts beyond
the word width. It also binds compiled ASTs for vault `deposit`, `startUnwinds`, `pokeSettle` and
accounting `beginHarvest`, `splitHarvest`; the vault bodies compose with exact selector/guard
prefixes and public transition preservation, while the harvest bodies have arithmetic and reserve
bounds. The extractor, semantic labeling and compiler remain trusted; see
[body proof scope](SOLIDITY_BODIES.md). Other contract bodies rely on differential comparisons.
`Solidity/GuardProofs.lean` binds the two `onlyVault` modifiers, both OpenZeppelin lock implementations,
32 leading entrypoint prefixes and the explicit transfer check to compiler ASTs. it proves rejection,
lock reset and conditional composition with the raw public invariant, including modeled rollback.
it does not establish whole-protocol callback safety; the exact limits are in the same scope record.
the comparison datasets contain 1,526 rows: 570 runtime, 352 coverage and 604 machine-boundary and history
cases. validation also includes 512 transfer-rounding fuzz cases, the public vault lifecycle,
rollback regressions, seeded rescale suites and public loss-recovery fixtures. all three generated
datasets reproduce exactly.
the Aave scaled-debt trace adds 516 calls with 43 expected reverts. the full formal check invokes
126 formal Foundry tests, 18 PR #79 regressions and the two targeted shared-flow histories,
all with zero failures or skips;
source fingerprints, all 19 accounting slots and the six private
Main batch slots also pass. the legacy environment-gated Verity fork suite is outside this formal gate.
the broader `test/formal/**` acceptance run passes 160 tests with zero failures; its only skip
is that legacy Verity fork setup, which is unavailable offline.
the repository-wide offline Forge run passes 738 tests with zero failures and 13 expected
fork/campaign skips.
the gate includes source-body extraction and 24 rejection/mutation tests for its supported AST
boundary, plus 24 guard-extractor tests. formal compiler remappings are fixed and relative, with automatic discovery disabled.
the production Paris build binds 11 contracts and 445 selectors, including the two loss-carry and
two parked-gift getters. CollateralVault is 24,495 bytes (81 bytes below the deployment limit),
JuicerYieldAccounting is 13,506 bytes, Harvester is 9,858 bytes and SubLoopLogic is 23,602 bytes.
this artifact refresh includes the executable PR #79 fixes.

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

this builds the proofs, regenerates and compares 1,526 cases across three datasets, checks source
fingerprints, compiled production artifacts and storage slots, then runs the comparison suites,
512 transfer-bound fuzz cases, the allowance, rounding and corrected account/request rescale
regressions, the 516-call Aave scaled-debt replay, PR #79 regressions and both shared-flow histories. after a reviewed
model change, regenerate with:

```sh
lake build
lake env lean --run ParityVectors.lean > runtime-vectors.json
lake env lean --run CoverageVectors.lean > coverage-vectors.json
lake env lean --run MachineVectors.lean > machine-vectors.json
```

Update the manifest after reviewing corresponding source/model changes. Fingerprints detect drift;
they are not correctness proofs. `--compiled` uses previously compiled modules from `LEAN_PATH`
for isolated verification.

`python3 check-bytecode.py` runs the production build and checks the artifact manifest on its own.

## proof boundary

The natural-number layer describes successful arithmetic. The checked layer adds uint256 failure
semantics for the operations listed above, with ABI/storage inputs in range. It is a functional
specification of Solidity arithmetic and the pinned math library, not a proof of the library's
assembly implementation. Valid configuration and truthful external observations remain premises.
Four 64-bit rescale steps suffice for an initial total below `2^256`; checked scale/epoch counter
overflow reverts rather than silently wrapping.

the 1,526 vector cases and 516 scaled-debt calls are cross-language comparisons, not a proof of
every Solidity trace. the lifecycle and Main transition systems derive their numerical partitions
from genesis and cover the listed call sequences. every successful checked `runCall` has a
kernel proof of the combined public invariant, and checked execution and replay preserve it for
arbitrary finite action lists from a certified input. `rawRunCall` remains the direct Solidity
model: universal acceptance of its successful results is false over arbitrary fabricated storage,
as the orphan-claim regression demonstrates.

`ValidSolidityAction` therefore combines the source-pinned fixture constraints with either a
proved structural input rule or a raw revert. the unconditional set is
approve, warp, repay, pull/repay-limit controls, vault/deposit/source pause controls, source
repricing, fee/cost controls, interest and price observations, peg maintenance, debt-rounding
controls, reserve/position funding, protocol-fee claims, haircut, tvl-cap changes and compound. transfer
requires caller < 5 and destination < 8; transferFrom requires owner < 5 and destination < 8,
with the fixture already restricting callers and owners to its four external holders. claim
requires a request index below the unwind cursor; sync, requestRedeem and deposit require consistent
account/request epochs and scales. requestRedeem requires an ordinary owner; deposit requires a
bounded receiver and zero reward index at zero supply. rebalance requires consistent metadata and
zero fee remainder at zero active source remainder. pokeSettle requires queue backing, consistent
batch weights/budgets, backed fees and bounded pull/cost rates; harvest requires the
post-checkpoint capped burn to fit the held source shares, which holds for every state. startUnwinds requires queue
backing, consistent metadata, ordinary waiting owners and bounded fee rates. all preservation results require the certified
input invariant; in particular, the orphan claim's fabricated input is not reachable.
`validSolidityTrace_invariant` proves every arbitrary finite raw
trace in that domain preserves `PublicInvariant`; `validSolidityReachable_invariant` gives the
equivalent inductive reachability result. the stateful runner now advances through the raw typed
dispatcher and checked all 9,690 default actions for domain membership using input rules or
reverts. metadata consistency is inductive even outside that domain. bounded source/fee rates and
ordinary stored request owners follow from initial bounds and fixture actions alone.

`ordinaryTrace_fixture_ready` proves financial preservation and all auxiliary call-readiness
conditions jointly from each of the three concrete fixture genesis states. `OrdinaryAction`
contains the fixture constraints, direct transfer callers below four, and a
started-claim-or-revert condition; it does not assume initialization, active-fee, queue, credit or
harvest safety. rollback remains part of the theorem. `CreditReadyHistory` keeps the source prefix
empty while a batch is suspended, preserves fee backing through repayments, keeps appended
positions outside the frozen batch tail, and restores fresh readiness on closure.

initialization depends on the locked address remaining unable to transfer. the older permissive
`ValidSolidityTrace` domain deliberately remains available, together with a kernel-checked trace
that refutes unconditional initialization induction over that larger domain. harvest capacity is
unconditional after applying Solidity's existing held-share cap; the capacity model remains the
single-vault `StatefulYieldSource` fixture, while live SubLoop capacity and multi-vault round
allocation remain separate correspondence obligations. the deposit model now checks the caller's
collateral balance before subtraction and performs the principal-floor check before reserve cover,
matching Solidity's revert and check order.
liability slots must represent
distinct holders or disjoint
waiting requests; all liabilities must be included in the initial representation. The new genesis
results remove the repeated numerical weight/partition assumptions, not that representation boundary.
The real-valued index proofs remain ideal arithmetic; exact integer equivalence would contradict
the checked rescale counterexample.
Main arithmetic, fee vesting, controller policies, source orchestration, retries and queue histories
have the coverage above. the source checker and universal theorem cover fixture target/selector
dispatch, but full contract-body equivalence, arithmetic outside the listed checked operations, upgrades
and whole-protocol reentrancy safety remain outside the kernel proof. the source-bound guard-prefix proofs
cover only the authorization and lock behavior described above. role-based access control and
trusted administrative configuration are not replaced
by the arithmetic models. protocol fee-controller binding/custody and the deployed Aave Pool remain
fixture boundaries rather than formalized external protocol implementations. the scaled-debt model
matches the pinned token history but does not prove Aave's assembly or arbitrary Pool behavior.

the rebalance model fixes the default band (target at the reserve's max LTV, relever 500 bps
under it, delever 300 bps over it), deposit admission fixes the loop's default 50 bps, and the
discount is Main-only; the fixture sources return those defaults. per-vault bands
(`SubLoop.setRebalanceBand`), a configured admission bound (`setAdmissionMaxDeficitBps`) and the
loop's HOLLAR discount (`JuicerDiscount.registerLoop`, `setLoopDiscountBps`) are outside the proved
model; the Solidity tests cover them. so is the entry fee (`JuicerFeeController.setEntryFeeBps`): the
model's deposit mints on the whole deposit, which is the contracts' default of no entry fee.

Aave/token observations must be truthful, oracle prices/configuration valid, and external calls
successful where their results are model inputs. matching ICE's 99%-minimum arrival heuristic
does not prove an arrival came from the intended solver; it also does not imply that the stricter
minimum required by an authenticated callback was received. Keeper/solver liveness, bounded market
losses and solvency cannot be derived from these arithmetic results. the reproducible compiler
templates are checked, but no deployed address or live-chain state was checked in this update.

The [older Verity bridge](bridge/PARITY.md) remains a simplified reference model. Neither its two
mock tests nor the artifact fingerprints establish bytecode-to-Lean semantic equivalence or a
live-Aave run.
