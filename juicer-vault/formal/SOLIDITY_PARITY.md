# current Solidity mapping

reviewed against the allowance fix based on `juicer-next` at
`c5eeec5a64bf1bf7bf33647d3265fca9ef53ebd3`, 9 october 2026.
accounting now rejects unrepresentable funded debits and preserves the requested allowance
bound; [rounding evidence](ROUNDING.md) records the remaining recipient display rounding.
`solidity-manifest.json` pins the source and model inputs; the check fails if they change without
a new comparison.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle` | 48 epoch, cap and shift cases |
| lazy account histories | `LazyLedger`, `normalizeAccount`, `normalizeLedger` | finite trace bounds, exact account-view/settlement/scale normalization; seeded rescale counterexample |
| `settle` / `_take` | `Runtime.take`, `fundedOf` | exact sender debit, full/fine-unit availability, conservation and 86 success/revert cases |
| `_allocate` | `Runtime.allocate`, `rescale` | 48 cases: virtual +1, fees, capital gifts, self-compounding, write-off and rescale |
| `startExit` | `Runtime.startExit` | 64 request epoch, committed unit, accrual, fee rounding and funded fold cases |
| `requiredSourceBacking` | `Runtime.requiredBacking` | 48 cash, interest and fee cases, including 100% fee |
| `splitHarvest` | `Runtime.splitHarvest` | 32 rounding, service fee and harvest reset cases |
| `SubLoopStorage` views; `SubLoopLogic.deLever` | `Runtime.outcome`, `inFlight`, `effectiveAccount`, `totalEquity`, `deLeverTarget` | 80 arrival, USD8, unflagged collateral, reserved cash, zero debt and target cases |
| `SubLoopLogic.execute` | `Runtime.callback` | 64 caller/owner, nonce, kind, output token and minimum cases |

| Main borrowing, cohort exit split and repayment | `mainBorrow`, `mainExit`, `mainRepay` | cash/unit isolation proofs; 48 public-call sequences |
| frozen source cash/cost batches | `batchSegment`, `batchCashTrace`, `batchCostTrace` | full-list telescoping conservation and no overcredit; 48 two-cohort comparisons; existing 64-item batch regression |
| vested source fees | `vestFee`, `settleFee` | junior fee bounds, cost reduction, no early charge; 48 comparisons |
| protocol reserve | `reserveDraw`, `spendable`, `repaymentLimit` | no active/unfinished draw, amount caps and protected fee cash; existing reserve regressions |
| controller credit, pacing, expiry and safety lanes | `Policy`, `available`, `policyCharge`, `executionMinimum` | credit/size bounds, no refill on refresh, quote only tightens oracle floor; 64 availability and 32 executed quote comparisons |
| FIFO start and collateral claims | `queueReady`, `startQueue`, `settleRedemption`, `claimRedemption` | work/FIFO bounds, full final burn, recipient protection; 32 queue and 48 claim comparisons |
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

Main's batch proofs cover arbitrary finite lists of frozen cohort weights, including exact cash
and cost totals and per-cohort reduction caps. The repayment model uses observed cash paid and
debt reduced separately; `payValid` states the external observation checks. The actual retry,
source batching cursor and external calls remain Solidity orchestration exercised by regressions.

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

425 source theorem/lemma declarations compile. The axiom audit checks all 830 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. the targeted Foundry suites pass 187 distinct comparison/regression tests, with zero failures
and skips, including 826 comparison vectors, 512 transfer rounding fuzz cases, eight
public-call allowance regressions, the seeded lazy-rescale fixture and the existing Main, fee,
controller, ICE, yield and invariant suites. the rescale investigation adds 17 further
exploratory tests across the four `Rescale*` suites (one of them a 256-case fuzz). Both
generated datasets reproduce exactly; the formal suites contain 31 tests. The London production build passes all size checks: CollateralVault remains 24,480
bytes, and JuicerYieldAccounting is 12,513 bytes (117 bytes larger).

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

This builds the proofs, regenerates and compares 826 cases across two datasets, checks source
fingerprints and storage slots, then runs the comparison suites, 512 transfer rounding fuzz cases,
the public-call allowance regressions and the seeded lazy-rescale case. After a reviewed model
change, regenerate with:

```sh
lake build
lake env lean --run ParityVectors.lean > runtime-vectors.json
lake env lean --run CoverageVectors.lean > coverage-vectors.json
```

Update the manifest after reviewing corresponding source/model changes. Fingerprints detect drift;
they are not correctness proofs. `--compiled` uses previously compiled modules from `LEAN_PATH`
for isolated verification.

## proof boundary

Natural-number models assume valid uint256 bounds, valid configuration and successful external
calls. Nonzero divisors and guarded subtraction match the successful Solidity paths; arbitrary
corrupt storage and every overflow/revert are not modeled. Four 64-bit rescale steps suffice for
an initial total below `2^256`, proved by `rescale_four_suffices`.

The 826 cases are cross-language comparisons, not a proof of every Solidity trace. The integer
lazy-history results bound rounding under explicit initial-state and weight premises. Normalization
matches ordinary account views and the listed arithmetic primitives; deriving every model step
from the complete vault/request/queue call sequence remains open. The holder list must represent
distinct holders or disjoint weights, with no omitted liability in its claimed initial bound.
The real-valued index proofs remain ideal arithmetic; exact integer equivalence would contradict
the checked rescale counterexample.
Main arithmetic, fee vesting, controller policies and queue arithmetic now have the coverage above;
complete cross-contract orchestration, all revert/overflow paths, upgrades and reentrancy remain
outside the kernel proof. Access control and trusted administrative configuration are not replaced
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
