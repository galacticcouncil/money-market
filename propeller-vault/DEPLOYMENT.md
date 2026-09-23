# Propeller Deployment Runbook

**RC1 | 23 September 2026 | Production activation blocked**

Audience: deployment, governance and operations reviewers. Complete the
[activation gates](docs/release-candidate.md#activation-gates) before authorizing
production transactions. This runbook supports a reviewed fresh deployment;
it does not approve production settings or upgrade a live old-buffer deployment.

**Check individual EVM outcomes.** `dispatcher.dispatchAsAaveManager` can report
reverts as `ExecutedFailed` events while the enclosing extrinsic succeeds.
Inspect every dispatched result and run the read-only readiness checker;
referendum enactment alone is not wiring verification.

## 1. Prepare the Deployment Manifest

Record the exact commit, compiler settings, dependency pins, runtime version,
chain block/hash and all reviewed addresses and parameters. Use `hdx.tarn`
for Hydration reads and fresh Chopsticks rehearsals.

| Required input              | Verification                                                                                                                                                                                                      |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deployer and gas funding    | Contract-deployer authorization and actual EVM fee funding on the target chain. Do not assume historical testnet whitelist behavior.                                                                              |
| Pool and token addresses    | Read live reserve data for collateral, collateral aTokens, HOLLAR debt, PRIME and aPRIME. Override script defaults explicitly.                                                                                    |
| Governance and committee    | Actual dispatch/execution addresses, not member wallets or keeper keys. Record all admin, upgrader and guardian assignments.                                                                                      |
| Synthetic reserve           | Available asset ID, registration, $1 oracle, approved LTV/LT, disabled borrowing and correct receipt token. The proposal uses 1% LTV and 98% LT; Main sizing uses real collateral, not synthetic borrowing power. |
| Runtime routes              | Regenerate router references with `scripts/propeller/gen-router-reference.mjs`; confirm pallet indices and SCALE encoding.                                                                                        |
| Swap adapter                | Deploy and review the production HydraAugustus implementation and required sell routes. No governance-address placeholder in an activated vault.                                                                  |
| PRIME pricing and liquidity | Approve source provenance/freshness, Aave and pool-peg wiring, executable inventory and funded replenishment. See [pricing validation](docs/prime-pricing-replenishment.md).                                      |
| Execution and admission     | Approve floors, nonzero tranches, deposit/ramp limits and harvest sizing. `deployTranche` does not cap initial/upward source deposits.                                                                            |
| Rounding and bootstrap      | Fund locked initial shares and per-vault collateral reserves; verify native minimum balances and custody dust protection.                                                                                         |
| Fees and discounts          | Configure fee controller/recipient, per-vault rates, discount controller/committee and explicit approved discount. Defaults are not policy approval.                                                              |

Legacy deployment scripts contain testnet defaults. Never reuse a historical
`.env`, address registry or placeholder as an approved production manifest.
Keep signing secrets outside tracked files and archived evidence.

## 2. Deploy and Bind

Initialize the pinned `bil-vault/lib` dependencies and build with the
[documented settings](README.md#build-and-test). Run serially against the same
artifact directory. Recheck EIP-170: the candidate CollateralVault has only
195 bytes of runtime headroom.

From `propeller-vault`, the core deployment order is:

```sh
forge script script/DeploySynth.s.sol:DeploySynth --rpc-url "$RPC" --evm-version london
forge script script/DeployMain.s.sol:DeployMain --rpc-url "$RPC" --evm-version london
forge script script/DeployVaultTBTC.s.sol:DeployVaultTBTC --rpc-url "$RPC" --evm-version london
```

These are simulation commands, not a single automatic deployment sequence.
Each script requires its documented environment; later scripts consume addresses
from the earlier actual deployment. Only an approved deployment adds
`--broadcast --legacy --slow --gas-estimate-multiplier 200`.
The tBTC script reuses the recorded CollateralVault implementation.

Continue in dependency order:

1. Deploy one [Main debt ledger](script/DeployMainDebt.s.sol) per fresh vault
   using `MAIN_DEBT_VAULT`. Execute the printed governance `setMainDebt` call.
   The ledger requires no sponsored HOLLAR funding.
2. Deploy and bind the [fee controller](script/DeployFees.s.sol) after the ledger
   binding. Register every vault and verify the recipient and 5% initial rate.
3. Deploy and install the [Main discount controller](script/DeployDiscount.s.sol)
   through its separate governance batch. See [discount installation](docs/main-borrow-discount.md).
4. Complete source/harvester roles, native custody protection, routes and reserve
   wiring before the controlled bootstrap.

Record implementation and proxy addresses, the constructor-created
`CompoundLogic` helper, both immutable ledgers, adapter, controllers and
harvester. Compare deployed bytecode and proxy slots to the final artifacts;
deployment success alone is insufficient.

Missing roles or ledger/reserve bindings can make deposits revert. Other unset
parameters are unsafe rather than inert: zero tranche values disable caps, and
zero compound slippage means exact oracle-relative execution, not a universal
revert. Verify all settings explicitly.

## 3. Generate and Rehearse Governance Wiring

The [proposal task](../tasks/proposals/propeller.ts) generates preimages, not an
automatic approved deployment. Its four ordered groups are:

| Group                | Purpose                                                                                                                             |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 0: compound routes   | PRIME-to-collateral and collateral-to-HOLLAR routes. Empty route bytes resolve through runtime route storage.                       |
| 1: list reserve      | Register the synthetic native asset before initializing its Aave reserve.                                                           |
| 2: configure reserve | Apply approved synthetic collateral settings, disable borrowing and install the $1 source.                                          |
| 3: wire              | Source/vault/harvester roles, tranches, route IDs, swapper, compound floor, withdrawal delay, guardians and funded rounding policy. |

Main-ledger binding, fee installation and discount installation must also be
verified; do not assume these four groups include every external prerequisite.
Splitting the batches avoids the historically observed scheduler weight limit,
but each final batch still needs current weight and execution checks.

Provide `PROPELLER_SYNTH`, `PROPELLER_SUBLOOP`, `PROPELLER_HARVESTER`,
`PROPELLER_VAULTS`, `PROPELLER_SWAPPER`, `PROPELLER_GUARDIAN`,
`PROPELLER_FEE_CONTROLLER`, explicitly approved `PROPELLER_SLIPPAGE_PPM`,
tranche/compound settings and `PROPELLER_ROUNDING_RESERVES`.
The rounding policy requires one funded entry per vault; see the
[keeper policy format](looper/README.md). Review optional route overrides and
the per-vault withdrawal delay before generating:

```sh
npx hardhat propeller --network hydration
```

Rehearse the exact governance calls on a fresh local fork before submission.
Inspect every EVM event and permission change, including removal of unintended
deployer authority.

## 4. Bootstrap and Verify Readiness

Keep public deposits closed throughout rehearsal and bootstrap.

1. Verify pre-bootstrap wiring, routes, role assignments, oracle inputs,
   custody protection and the funded rounding reserve.
2. Governance makes the first approved deposit, funding the locked bootstrap
   shares. Public users must not bear that cost.
3. Confirm PRIME is enabled as source collateral and loop equity is recognized.
   Funding now enables collateral directly; ramping is **not** a prerequisite
   for an unlevered unwind.
4. Ramp only within approved native execution and liquidity budgets.
5. Run the full readiness checker after bootstrap. Its positive-equity and
   initial-share checks intentionally fail on an unseeded deployment.

Use the complete environment documented at the top of
[verify-readiness.ts](../scripts/propeller/verify-readiness.ts). It includes fee
and discount controllers/recipient/committee, explicit discount/slippage values
and the rounding policy, not just vault addresses.

```sh
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' scripts/propeller/verify-readiness.ts
```

The checker is read-only and exits nonzero on failure. Resolve every failed row;
passing it does not replace independent review or prove sufficient market depth.

## 5. Rehearse the Lifecycle and Operations

Use the exact adapter, registry, policy and artifacts intended for deployment.

- Both collateral vaults and multiple holders: deposit, ramp, harvest, fee claim,
  Main interest service and source-funded Main resizing.
- Withdrawal: request, wait until chain-time eligibility, `startUnwinds`,
  source repayment, `pokeSettle`, partial/final collateral claims and late
  source-surplus ownership.
- Incident: freeze eligible and already-settled claims, retain Main maintenance,
  fund recovery explicitly, reconcile every affected holder and only then reopen.
- Rounding: exhaust/refill a controlled reserve and verify exact retry without
  reducing principal or charging other holders.
- Execution: no unapproved price override, floor widening, gas-limit relaxation
  or hidden recovery funding in the final acceptance run.

The existing native success used a labeled oracle-update fixture and external
funding. A fresh unchanged-market acceptance run remains an activation gate.

Start the keeper using the [operations runbook](looper/README.md), with
`VAULT_ADDRESSES` covering every configured vault. Use one active sender per
signing key to avoid nonce collisions. Arrange independent monitoring, a funded
failover process and committee incident coverage; the keeper has no special role.

## Incident and Abort Checks

| Symptom                               | Investigation or control                                                                                                                            |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wiring transaction appears successful | Check every `ExecutedFailed` event, live state and readiness result before retrying missing calls.                                                  |
| Entry or unwind swap fails            | Check routes, reference price, inventory and executable size. Do not widen loss limits to force success.                                            |
| Harvest fails                         | Check complete harvester registry, both conversion routes, adapter balances/approvals and the fee/Main-ledger bindings.                             |
| Wrong source bound                    | Treat `setYieldSource` as deployment wiring, not live migration. Follow the [upgrade boundary](docs/source-upgrades.md); preserve all claims.       |
| User flows must stop                  | Use affected-vault pauses or the source-wide emergency freeze. Stopping the keeper or source route alone does not block existing claims.            |
| Route execution is unsafe             | Source `pause()` also stops safety swaps. Account for that loss of debt-reduction capability in the incident plan.                                  |
| Recovery is only partially funded     | Keep ordinary FIFO frozen; do not advantage early claimants. Follow [all-holder recovery policy](docs/principal-safety.md#fair-emergency-recovery). |

## Release Record

Before enabling public deposits, archive the exact reviewed commit, source hashes,
compiler/dependency settings, runtime bytecode, complete storage layout, deployed
addresses, roles, policy, proposal outcomes and successful acceptance evidence.
Record explicit sign-off for every [activation gate](docs/release-candidate.md#activation-gates).

The checked-in source layout is a research baseline, not a deployed upgrade
baseline. Future upgrades require a new compatibility and economic review.
