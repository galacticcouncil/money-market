# PR #60 Completion Checks

**25 September 2026 | Review preparation | Production activation remains blocked**

This follow-up reconciles the Main-servicing candidate with `propeller` through
`a0c4581` and closes the model replay failures recorded at the September 23 RC1
checkpoint. It does not change Solidity contracts, market parameters or oracle
addresses. The current implementation is [yield-funded Main servicing](main-debt-servicing.md);
the sponsored HOLLAR-buffer proposal and its ownership issue are historical.

## Changes

- Preserve the target branch's withdrawal-delay, strict FIFO and emergency-pause
  documentation while describing the candidate's implemented Main servicing.
- Share the entry-capacity search between pressure and route calibration. Check
  a one-HOLLAR trade first (or the explicit limit if smaller); an unexecutable
  marginal trade yields zero usable entry capacity. Stop searching through
  tiny amounts that round to zero or are rejected by the SDK.
- Treat an explicit SDK quote rejection as an unavailable fill. Propagate
  unexpected quote/predicate errors instead of hiding them as zero liquidity.
  Search boundaries remain integer amounts and never round an unsafe fill up.
- Replace snapshot-specific burn/price thresholds with reserve and burn-budget
  conservation checks. The September 23 HSM burn budget is larger than September
  22's; recovery above $0.99 is possible in the newer modeled shock. Donations
  still cannot increase the facilitator's burn budget.
- Add a repeatable replay command that selects both archived market snapshots,
  native route receipts and PRIME validation inputs. Missing, failed or skipped
  tests cause a nonzero exit. Each test log and market fixture has a SHA-256 hash.

## Model Verification

[Results and hashes](evidence/pr60-completion-2026-09-25/summary.json):
**167 passed, zero failed, zero skipped**, across 12 suite/fixture combinations.

| Suite | September 22 snapshot | September 23 route snapshot |
| --- | ---: | ---: |
| Pressure | 8 | 8 |
| Peg and finite HSM funding | 17 | 17 |
| Coupled liquidity | 24 | 24 |
| Interest policy comparison | 21 | 21 |
| Route calibration and native quote parity | — | 10 |
| PRIME replenishment | — | 4 |
| Historical trade calibration | — | 5 |
| Source storage checker | — | 8 |

The last three suites use their own explicit validation fixtures or synthetic
test inputs; the route snapshot environment does not change those inputs.
Native quote parity replays archived receipts, not new native transactions.

From the repository root, using the Hydration SDK packages recorded in the
summary's `mathDependencies`:

```sh
HYDRATION_MATH_ROOT=/path/to/sdk/packages \
  node scripts/propeller/verify-models.mjs /tmp/propeller-model-verification
```

If the two math packages are installed locally, `HYDRATION_MATH_ROOT` is optional.
The runner prints each suite's result and writes `summary.json` and TAP logs to
the output directory. Omitting the output argument creates a temporary directory.

## Contract and Tooling Regression

[Regression results, runtime hashes and Solidity log](evidence/pr60-completion-2026-09-25/regression.json):

- Solidity: **287 passed, zero failed, 11 skipped** using the production London
  target. Nine stateful invariants ran 256 sequences of depth 50. The skips are
  eight opt-in campaign cases and three optional fork/Verity setups.
- All seven production runtime templates match the September 23 evidence, and
  artifact source metadata matches the local files. CollateralVault remains
  **24,381 bytes**, with **195 bytes** of EIP-170 headroom.
- Keeper: **19 tests passed** and TypeScript build passed. Standalone readiness
  typechecking, three native-rounding tests and Hardhat task loading also passed.

From `propeller-vault`, run `forge test --offline --evm-version london`.
From `propeller-vault/looper`, run `npm test` and `npm run build`.
The broader native-fork and 2,220-scenario campaign evidence remains the archived
September 23 result; this follow-up did not rerun those campaigns.

## Remaining Scope

The [production activation gates](release-candidate.md#activation-gates) remain
open: strict unchanged-market entry, approved oracle wiring, funded replenishment,
admission/harvest sizing, executable TVL and ramp limits, governance recovery,
operations and independent exact-artifact review. Passing an archived replay
does not establish provider commitments or demonstrate a fresh deployment.

The full repository TypeScript configuration retains its pre-existing duplicate
STHDX oracle key in `markets/hydration/index.ts`. This follow-up does not select
a production feed; Propeller readiness is typechecked separately.
