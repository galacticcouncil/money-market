# current Solidity mapping

reviewed against the allowance fix based on `juicer-next` at
`ddf818666b471a8dfe788863d1522afe1c871651`, 9 october 2026.
accounting now rejects unrepresentable funded debits and preserves the requested allowance
bound; [rounding evidence](ROUNDING.md) records the remaining recipient display rounding.
`solidity-manifest.json` pins the source and model inputs; the check fails if they change without
a new comparison.

| implementation | current Lean model | evidence |
| --- | --- | --- |
| `SyntheticFloor.buffered` | `Runtime.buffered`; `IState.repegSynth` | universal floor theorem, including one wei; 36 comparisons |
| `CompoundLogic.rebalance` budget | `State.borrowCapacity` excludes synthetic; `aaveBorrowCapacity` includes it | algebraic independence proof; source subtracts synthetic from the collateral base |
| `JuicerYieldAccounting.balanceOf`, `_settle` | `Runtime.accountUnits`, `settle` | 48 epoch, cap and shift cases |
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

386 source theorem/lemma declarations compile. The axiom audit checks all 766 kernel theorem
declarations, including generated lemmas, and finds only `propext`, `Classical.choice` and
`Quot.sound`. The targeted Foundry suites pass 186 distinct tests, with zero failures and skips,
including 826 comparison vectors, 512 transfer rounding fuzz cases, eight public-call allowance
regressions and the existing Main, fee, controller, ICE, yield and invariant suites. Both generated
datasets reproduce exactly. The London production build passes all size checks: CollateralVault
remains 24,480 bytes, and JuicerYieldAccounting is 12,513 bytes (117 bytes larger).

## reproduce

From `juicer-vault/formal`, with the pinned Lean/Mathlib dependencies and Foundry installed:

```sh
python3 check-runtime.py
```

This builds the proofs, regenerates and compares 826 cases across two datasets, checks source
fingerprints and storage slots, then runs the comparison suites, 512 transfer rounding fuzz cases,
and the public-call allowance regressions. After a reviewed model change, regenerate with:

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

The 826 cases are cross-language comparisons, not a proof of every Solidity trace. The real-valued
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
