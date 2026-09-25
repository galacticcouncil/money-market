# Propeller RC1

**Release candidate for review, 2026-09-23. Production activation is blocked.**
RC1 designates this code/documentation checkpoint, not a production deployment,
unconditional principal guarantee, audit sign-off or approval of market limits.

The candidate is on `feat/propeller-interest-buffer`; the name is historical.
Sponsored operating buffers have been replaced. The commit containing this
document identifies the candidate; [runtime hashes](evidence/route-execution-2026-09-23/summary.json)
identify its seven production contract templates. No release tag is implied.

## Included

- Technical Committee-controlled Main borrowing discounts and governance-set
  per-vault collateral fees, initially 5%, permissionlessly claimable to the
  owner's configured recipient. PRIME-loop borrowing is not discounted.
- Main interest servicing from fresh after-fee harvests; source-funded Main
  resizing when collateral value falls. No mandatory sponsored HOLLAR buffer.
- Earned PRIME retention for execution costs, strict swap floors, and no
  automatic widening. Retention is not funded insurance and can delay harvests.
- Principal rounding protections, preserved unpaid source claims and original
  exit ownership. Deposits block while underfunded; governance funds recovery.
- Configurable withdrawal delay, initially 12 hours before unwinding, plus
  emergency controls. Fair all-holder emergency accounting remains a manual
  governance responsibility, not an implemented automatic settlement engine.
- Keeper/readiness changes, source-upgrade storage/accounting compatibility
  tests and a documented future source-rotation plan. Rotation itself is deferred.

## Verification

[Final regression logs and runtime hashes](evidence/rc1-2026-09-23/summary.json)
are archived with the candidate. Native and campaign evidence retains its
separate fixture and funding assumptions.

| Check                           | Result and scope                                                                                                                                                                          |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Solidity regression             | 287 passed, zero failed, 11 optional tests/setups skipped; final unfiltered run                                                                                                           |
| Source upgrade compatibility    | Seven contract cases and eight storage-checker tests; no migration implementation                                                                                                         |
| HydraAugustus candidate         | 19 swap and seven configuration tests; five native sell routes exercised                                                                                                                  |
| Native lifecycle                | Both vaults/four users, harvest servicing, delay, emergency recovery, exact collateral and late-source payouts passed with a labelled oracle-update fixture and external recovery funding |
| Native Main resize              | PRIME loop shrank and Main debt fell without consuming user collateral; test LTV restored                                                                                                 |
| 90-day actual-contract campaign | 2,220 scenario executions across six TVLs, five paths and retention/cost comparisons; Aave/router boundary mocked, recovery explicitly funded                                             |
| Pricing/refill validation       | Fresh Hastra reference, live replacement oracle/guard and NTT/reserve reads; replenishment commitment not established                                                                     |
| Runtime size                    | CollateralVault 24,381 bytes, 195 bytes below EIP-170; no native size/gas-limit relaxation                                                                                                |

The [September 25 completion checks](pr60-completion.md) close the recorded
snapshot-replay failures: the capacity search handles rejected quotes and the
peg tests check each snapshot's actual reserve and burn budgets. The pressure,
peg, coupled and policy suites now pass on both September 22 and September 23
snapshots. The complete model/calibration replay passes **167 tests with no
skips**, including native quote parity against archived receipts. Those results
do not establish funded replenishment or a safe production TVL. The original
September 23 failure logs remain archived as historical evidence.

The final unfiltered regression includes eight inherited campaign-fixture tests
not counted in the earlier 279-test scoped run. Its 11 skips are eight opt-in
campaign cases plus three optional fork/Verity setups. The separate campaign
evidence covers its explicitly enabled scenarios; skips are not converted into
passes. Existing formal proofs do not cover all revised Main-ledger or
execution-allowance behavior. Donated PRIME in the native harvest test is not
organic APY; preserving principal after external recovery is not self-funding.

## Activation Gates

| Gate                                    | State      | Evidence required to close                                                                               |
| --------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------- |
| PRIME reference and wiring              | Open       | Correct replacement feed, provenance/freshness approval, Aave and pool-peg governance wiring             |
| Strict entry on unchanged market        | Blocked    | Fresh native lifecycle passing approved limits without an oracle-price or relaxed-floor fixture          |
| Funded replenishment                    | Open       | Provider/inventory funding, executable spreads, size/day capacity and settlement/outage budgets          |
| Admission and harvest sizing            | Open       | Initial/upward deposits and harvests bounded or queued; `deployTranche` alone does not cap them          |
| TVL/ramp/slippage policy                | Unapproved | Limits justified by market liquidity, money-market cash, HSM funding and keeper throughput               |
| Governance recovery and operations      | Open       | Funded backstop, all-holder recovery procedure, monitored/redundant keepers and emergency drill          |
| Final deployment and independent review | Open       | Exact-bytecode review, production adapter deployment/roles/routes, fresh end-to-end governance rehearsal |

## Team Review

| Workstream                | Next deliverable                                                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Oracle and risk review    | Approve provenance, freshness/outage behavior and coordinated Aave/pool-peg wiring; replay gradual peg convergence.                               |
| Liquidity and treasury    | Confirm funded PRIME replenishment, two-way execution budgets, shared stablecoin capacity and governance recovery funding.                        |
| Contract engineering      | Bound admission/harvest sizes, close applicable accounting review findings and retain exact principal/claim ownership tests.                      |
| Research                  | Complete the provider-calibrated six-TVL coupled campaign. Snapshot-replay failures are closed; historical turnover is not a provider commitment. |
| Governance and operations | Approve launch parameters, exact roles, monitored keepers, pause coverage and a rehearsed recovery process.                                       |
| Release reviewers         | Review the exact final artifacts and sign off on the fresh governance/native acceptance run.                                                      |

These are review responsibilities, not claims that specific people or teams have
accepted ownership. No launch date or production TVL is approved by this RC.

Do not enable public deposits until these gates have explicit sign-off. A new
contract change requires rebuilding, rechecking EIP-170 and rerunning affected
verification; a docs-only RC designation cannot close a technical gate.

## Evidence Index

- [Main debt policy](main-debt-servicing.md) and [principal protection](principal-safety.md).
- [Production adapter, native workflow and retention results](route-execution-calibration.md).
- [PRIME pricing and replenishment validation](prime-pricing-replenishment.md).
- [Source upgrade compatibility and deferred rotation](source-upgrades.md).
- [Deployment runbook](../DEPLOYMENT.md) and [keeper operations](../looper/README.md).
- [All resources and historical branch structure](README.md).
