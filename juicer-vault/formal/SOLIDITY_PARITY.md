# current Solidity mapping

Reviewed against `juicer-next` at `bbe541fcd6b12b955d539539c3462c700b246dbc`, 9 October 2026.
Contract code is unchanged by this formal update. The expanded investigation found an open
[funded-transfer allowance mismatch](ROUNDING.md). `solidity-manifest.json` pins the source
and model inputs; the check fails if they change without a new comparison.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle` | 48 epoch, cap and shift cases |
| `settle` / `_take` | `Runtime.take`, `fundedOf` | conservation/cap proofs and 80 success/revert cases |
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
projection preserves its unit bound across finite allocation/rescale/transfer/exit/write-off
traces. Its holders are already settled; it is not a proof that every lazy account history
commutes with that projection. `lazy_index_rescale_error` separately bounds the shifted index
difference, which can round upward even though individual stored words shift downward.

Main's batch proofs cover arbitrary finite lists of frozen cohort weights, including exact cash
and cost totals and per-cohort reduction caps. The repayment model uses observed cash paid and
debt reduced separately; `payValid` states the external observation checks. The actual retry,
source batching cursor and external calls remain Solidity orchestration exercised by regressions.

`LeanCoverageParity.t.sol` calls actual Main/controller/claim implementations. Main sequences
enter through vault-authorized public methods; claim and availability cases use inherited
harnesses to seed their state. Pool, source and fee-sink behavior is supplied by fixtures.
`LeanRoundingReachability.t.sol` separately reproduces the allowance mismatch through public
vault operations, without seeding accounting storage. The model comparison cases are not
reachability proofs for every seeded state.

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
  layer includes them. A rounded unit transfer need not move exactly the requested displayed
  base units; `take_rounding_example` is a checked counterexample to that stronger claim.
- `freedBacked` is a solvency hypothesis, not an on-chain deposit gate. `collSold` is a hypothetical
  shortfall diagnostic; current collateral claims remain owed during underfunding.

## verification

377 source theorem/lemma declarations compile. The axiom audit checks all 742 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. The combined Foundry run passes 172 tests, with zero failures and skips, including
820 comparison vectors, 512 transfer-bound fuzz cases and the existing Main, fee, controller,
ICE, yield and invariant suites. Both generated datasets reproduce exactly.

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

This builds the proofs, regenerates and compares 820 cases across two datasets, checks source
fingerprints and storage slots, then runs the comparison suites, 512 transfer-bound fuzz cases,
and the public-call rounding reproduction. After a reviewed model change, regenerate with:

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

The 820 cases are cross-language comparisons, not a proof of every Solidity trace. The real-valued
index proofs do not yet refine arbitrary histories of lazy account settlement and rescaling.
The new integer ownership trace theorem applies to the settled-cohort projection, with explicit
weight/unit bounds, rather than asserting exact integer equivalence to the ideal real-valued model.
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
