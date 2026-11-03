# Juicer Deployment Runbook

**Launch candidate, PR #89 | 3 November 2026 | Not deployed**

Audience: deployment, governance and operations reviewers. Complete the
[activation gates](docs/release-candidate.md#activation-gates) before authorizing
production transactions. This runbook supports a reviewed fresh deployment;
it does not approve production settings or upgrade a live old-buffer deployment.

The [#62 ownership implementation](docs/pr62-completion-2026-10-02.md) requires
a fresh, matching vault/source/Main/ownership/fee/Harvester stack. Its new source
cost bases and reward ownership cannot be initialized by preserving old storage
slots alone. Do not apply this runbook as an upgrade of funded older vaults.
The current version is fresh-deploy only as well: its yield accounting drops
claims and changes storage.

The launch is three steps, in order: a deploy-only step that creates every
contract with governance as admin, one Root referendum that lists, wires, funds
and opens it, and a read-only readiness check before anything is announced.
The deployer's only call after its creations hands the swap adapter to
governance. The [review package](docs/external-review.md#8-deployment-and-launch)
describes the same process for reviewers.

**Check individual EVM outcomes.** `dispatcher.dispatchAsAaveManager` can report
reverts as `ExecutedFailed` events while the enclosing extrinsic succeeds.
Inspect every dispatched result and run the read-only readiness checker;
referendum enactment alone is not wiring verification.

## 1. Prepare the Inputs

Record the exact commit, compiler settings, dependency pins, runtime version,
chain block/hash and all reviewed addresses and parameters. Use an archive node
for reads and fork rehearsals.

| Required input              | Where it is set and how it is checked                                                                                                                                                                    |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deployer and gas funding    | A contract-deployer authorization and EVM fee funding on the target chain. `launch-deploy.mjs` refuses an unauthorized deployer. The key is read from `JUICER_DEPLOYER_KEY_FILE`, a path, never the key. |
| Pool and token addresses    | `scripts/juicer/launch-manifest.mjs` pins the pool, HOLLAR and its debt token. `launch-deploy.mjs` reads aPRIME, the Aave treasury and each collateral's aToken from the pool; it refuses another HOLLAR debt token or a collateral without a reserve. |
| Governance and committee    | `GOV` (the pool admin's EVM origin, reached through `dispatchAsAaveManager`) and `COMMITTEE` in `launch-manifest.mjs`: execution addresses, not member wallets or keeper keys.                          |
| Vaults                      | `VAULTS` in `launch-manifest.mjs`: jBTC on tBTC (1000765) with a 1.337 tBTC TVL cap (`JUICER_TVL_CAP_TBTC` overrides it). `JUICER_LAUNCH_VAULTS` selects them (default `TBTC`); jETH on GIGAETH (4200) needs a later referendum. |
| Synthetic reserve           | The referendum registers asset 5550 (`JUICER_SYNTH_ASSET_ID`) and lists it with 1% LTV, 98% LT, borrowing off and the $1 source. Main sizing uses real collateral, not synthetic borrowing power.      |
| Runtime routes and indices  | Regenerate router references with `scripts/juicer/gen-router-reference.mjs`. `DcaDispatch` pins `router.sell` (67/0) and `intent.submitIntent`/`removeIntent` (98/0, 98/1); readiness checks them.    |
| Swap adapter                | The pinned HydraAugustus build from its own repository (`JUICER_ADAPTER_ARTIFACT`). The deploy hands it to governance; the referendum maps PRIME 43, HOLLAR 222 and each collateral with `setAssetId`. |
| PRIME pricing and liquidity | Approve source provenance/freshness, Aave and pool-peg wiring, executable inventory and funded replenishment. See [pricing validation](docs/prime-pricing-replenishment.md).                            |
| Launch values               | `NEXT` and `LAUNCH` in `scripts/juicer/next-governance.ts`, the constants in `tasks/proposals/juicer.ts` and `launch-manifest.mjs`, most with an environment override. See the [launch values](docs/external-review.md#launch-values). |
| Keepers                     | `JUICER_KEEPERS`: the referendum grants each `KEEPER_ROLE` on the loop and `DEPOSIT_GUARDIAN_ROLE` on each vault, and nothing else.                                                                       |

The forge scripts in `script/` are an earlier deployment path and contain
testnet defaults; the launch does not use them. Never reuse a historical
`.env`, address registry or placeholder as an approved production manifest.
Keep signing secrets outside tracked files and archived evidence.

## 2. Build

From `juicer-vault`, after initializing the pinned `bil-vault/lib` submodules
([build and test](README.md#build-and-test)):

```sh
forge build src ../bil-vault/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol \
  --offline --evm-version london --skip test --skip script --sizes \
  --out out-production --cache-path cache-production --build-info
```

This is the production build CI runs. Besides `src` it compiles the
OpenZeppelin `ERC1967Proxy` that `launch-deploy.mjs` deploys for the loop and
each vault; a build of `src` alone does not emit it. Recheck EIP-170 in the size
table against these exact artifacts.

`foundry.toml` supplies Solc 0.8.22, via IR and optimizer 200; the London
override is required, and the deploy refuses an artifact built for another EVM
version. Forge auto-detects remappings for `../bil-vault/lib` as absolute paths
and every contract's metadata hash covers them, so only the deploy checkout's
path and submodule layout reproduce the deployed bytecode exactly. Neckwork
publishes those paths with the source: deploy from a neutral path that names no
person.

## 3. Deploy Only

From the repository root:

```sh
JUICER_ARTIFACT_DIR=juicer-vault/out-production JUICER_ADAPTER_ARTIFACT=<HydraAugustus.json> \
  JUICER_DEPLOYER_KEY_FILE=<key file> RPC=<eth rpc> \
  node scripts/juicer/launch-deploy.mjs <manifest.json>
```

`WS` defaults to `RPC` over websockets. For jBTC the script creates, in order:
HydraAugustus, CompoundLogic, the vault implementation, SyntheticToken,
SubLoopLogic, the SubLoop implementation and proxy, Harvester,
JuicerFeeController (recipient: the Aave treasury), ExecutionController (60 s,
5 blocks), JuicerDiscount, the jBTC proxy and its JuicerMainDebt. It then hands
HydraAugustus to governance; a two-step adapter leaves `acceptOwnership` to the
referendum.

Each creation is estimated with a 10% margin and checked against the 2²⁴ gas a
Hydration transaction carries, initcode against EIP-3860 and the runtime against
EIP-170 and its artifact outside immutables. The manifest records every
creation and call, so a rerun resumes where the last one stopped and refuses
code that changed since. At the end it checks that the deployer holds none of
the nine roles anywhere, governance holds every admin role and the committee the
discount's rate role, the proxies point at their implementations with no proxy
admin, the implementations refuse `initialize`, the Main ledgers are not bound
yet, and the deployer sent nothing unrecorded.

JuicerDiscount binds the synthetic's aToken before the reserve exists, at the
pool configurator's next creation. Any listing enacted before the referendum's
`initReserves` moves that address. If it lands before the proposal is generated,
`juicer.ts` refuses to emit and a rerun of the deploy creates a new discount for
the new prediction; if it lands later, readiness fails the aToken binding
([recovery](docs/external-review.md#5-known-issues-and-accepted-risks)).
`--fork` deploys with a public dev key to local endpoints only, for rehearsals.

### Verify on Neckwork

Before submitting the referendum, verify every deployed contract on the
[Neckwork explorer](https://hydration-explorer.neckwork.net), which indexes
Hydration mainnet (chain 222222) only. In the deploy checkout, at the deploy
commit and with the build from step 2, review the dry run, submit, then confirm:

```sh
node scripts/juicer/verify-contracts.mjs <manifest.json> --out juicer-vault/out-production --out <adapter build>
node scripts/juicer/verify-contracts.mjs <manifest.json> --out juicer-vault/out-production --out <adapter build> --live
node scripts/juicer/verify-contracts.mjs <manifest.json> --check
```

The script reads the manifest's creations and the helpers it records. The
manifest keeps no init code, so each contract is matched by name against the
build-info (`unchecked`) and submitted without its creation transaction:
Neckwork matches the runtime code. HydraAugustus needs its own repository's
build with build-info as a second `--out`. `--live` skips verified addresses,
stays within Neckwork's ten submissions a minute, polls every job and resumes
when rerun. It exits nonzero until every contract verifies.

Each `ERC1967Proxy` verifies against the proxy in the same build, and each Main
ledger's constructor-created `JuicerYieldAccounting` from its address in the
manifest.

On `mismatch` or a failed job, stop before the proposal. Rebuild from the deploy
commit into clean `out-production` and `cache-production`; check the EVM version,
via IR, optimizer runs and Solc version against the manifest; check
`git submodule status` and the checkout path. A `partial` result verifies the code
but not its metadata; only a rebuild in the deploy checkout matches exactly.

## 4. One Root Referendum

From the repository root:

```sh
JUICER_MANIFEST=<manifest.json> JUICER_KEEPERS=<keeper addresses> JUICER_PLAN_OUT=<plan.json> \
  RPC=<eth rpc> MARKET_NAME=Hydration HARDHAT_NETWORK=hydration npx hardhat juicer
```

The [proposal task](../tasks/proposals/juicer.ts) reads the manifest and the
chain, then plans only what the chain lacks, so a rerun after enactment proposes
nothing. Its steps, in order:

| Step      | Calls                                                                                                                                                                                                                                 |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chain     | pool 143 fee to 1 bp; the harvest and servicing routes the router lacks; the synthetic registered as ERC20 asset 5550, then `initReserves`, its collateral settings and the $1 source; each share registered as a sufficient ERC20 asset |
| custody   | duster whitelist for the loop, Harvester, fee controller, each vault, Main ledger and yield accounting, and the adapter                                                                                                                 |
| funding   | from the treasury to governance's account: collateral for rounding and the bootstrap, HOLLAR for the reserves; the loop's fee currency reset to WETH, with WETH and HDX for its ICE callbacks                                           |
| wire      | loop tranches, route and Harvester; the Harvester's fee controller; per vault `MINTER_ROLE`, `VAULT_ROLE`, `setMainDebt`, fee controller and registration, Harvester, compound slippage, withdrawal delay; the committee's `GUARDIAN_ROLE`; the adapter's asset ids |
| execution | budgets, pacing, lane limits and price caps, the quote entrypoints, then `setExecutionController` on the loop, Harvester and vaults                                                                                                     |
| discount  | JuicerDiscount installed on the HOLLAR debt token; each vault's `setDiscountController` and registration; `registerLoop` with its cap                                                                                                  |
| next      | the keepers' roles, harvest threshold, ICE and async lanes, bands, admission, headroom exits, the revenue mix                                                                                                                         |
| reserve   | `fundReserve` on each Main ledger                                                                                                                                                                                                     |
| rounding  | each vault's rounding reserve, sized from the collateral's existential deposit                                                                                                                                                         |
| open      | governance's bootstrap deposit, last, sized in the collateral's decimals                                                                                                                                                               |

The calls pack into batches of at most 40% of the scheduler's maximum block
weight (`JUICER_BATCH_WEIGHT_PCT`), by measured weight. Batch 0 runs at
enactment and schedules each later batch with `scheduler.scheduleAfter`, one
block each. A failed batch does not stop the next one. The task prints each
batch, the proposal and its hash; `JUICER_PLAN_OUT` keeps the plan, including
the execution policy and launch values readiness needs.
`JUICER_FUNDING_SOURCE=admin` funds from a prefunded governance account instead
of the treasury.

Rehearse the exact proposal on a fork of mainnet before submission
([mainnet-fork rehearsal](docs/external-review.md#mainnet-fork-launch-rehearsal)):
`scripts/juicer/launch-rehearsal.mjs` enacts it, mines every scheduled batch and
reports each block's EVM calls and failure events. Inspect every permission
change, including the absence of deployer authority. Submit the proposal as one
Root referendum.

## 5. Verify Readiness

After every scheduled batch has executed, from the repository root, with `WS`
and `RPC` set:

```sh
eval "$(node scripts/juicer/launch-manifest.mjs <manifest.json> <plan.json>)"
npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' scripts/juicer/verify-readiness.ts
```

The manifest supplies the addresses and the CompoundLogic code hash, the plan
the approved execution policy and launch values. The checker is read-only and
exits nonzero on failure: the runtime's pinned call indices, the synthetic's
registration and reserve, bytecode, roles and wiring, execution limits, each
vault's configuration, rounding and custody, the fee and discount bindings
including the synthetic's aToken, the keepers, admission, bands and headroom
exits, and the launch wiring. Loop equity passes after the first rebalance.
Resolve every failed row before anything is announced; passing it does not
replace independent review or prove sufficient market depth.

## 6. Rehearse the Lifecycle and Operations

Use the exact adapter, registry, policy and artifacts intended for deployment.

- Each launched vault and multiple holders: deposit, ramp, harvest, fee claim,
  Main interest service and source-funded Main resizing.
- Withdrawal: request, wait until chain-time eligibility, `startUnwinds`,
  source repayment, `pokeSettle`, partial/final collateral claims and late
  source-surplus ownership.
- Incident: freeze eligible and already-settled claims, retain Main maintenance,
  fund recovery explicitly, reconcile every affected holder and only then reopen.
  Vault or source-wide emergency freezes stop `claim` and `startUnwinds`;
  `pokeSettle` remains available to advance settlement. Only a vault's own pause
  stops share transfers, and it cannot be added once the source emergency is set.
- Deficit stop: a simulated deficit makes a keeper set `deficitStop` and stop
  the ramp; recovery below the resume level clears it. Governance's
  `pauseDeposits` stays untouched throughout.
- Rounding: exhaust/refill a controlled reserve and verify exact retry without
  reducing principal or charging other holders.
- Execution: no unapproved price override, floor widening, gas-limit relaxation
  or hidden recovery funding in the final acceptance run.

The existing native success used a labeled oracle-update fixture and external
funding. A fresh unchanged-market acceptance run remains an activation gate.

Start the keeper using the [operations runbook](looper/README.md), with
`VAULT_ADDRESSES` covering every configured vault. Use one active sender per
signing key to avoid nonce collisions. Arrange independent monitoring, a funded
failover process and committee incident coverage. Without `KEEPER_ROLE` a keeper
sends the permissionless pokes at the oracle floor; without
`DEPOSIT_GUARDIAN_ROLE` it still holds its ramp on a deficit and alerts, but
cannot stop deposits.

## Incident and Abort Checks

| Symptom                               | Investigation or control                                                                                                                            |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wiring transaction appears successful | Check every `ExecutedFailed` event, live state and readiness result before retrying missing calls.                                                  |
| Entry or unwind swap fails            | Check routes, reference price, inventory and executable size. Do not widen loss limits to force success.                                            |
| Harvest fails                         | Check complete harvester registry, both conversion routes, adapter balances/approvals and the fee/Main-ledger bindings.                             |
| Wrong source bound                    | Treat `setYieldSource` as deployment wiring, not live migration. Follow the [upgrade boundary](docs/source-upgrades.md); preserve all claims.       |
| User flows must stop                  | Pause affected vaults, then the source-wide freeze if needed; only vault pauses stop transfers. Stopping the keeper or route blocks no claims.      |
| Deposits stopped unexpectedly         | Check `depositsPaused` (guardian) and `deficitStop` (keepers) apart. A keeper clears only its own stop, below `DEFICIT_RESUME_BPS`.                 |
| Route execution is unsafe             | Source `pause()` also stops safety swaps. Account for that loss of debt-reduction capability in the incident plan.                                  |
| Recovery is only partially funded     | Keep ordinary FIFO frozen; do not advantage early claimants. Follow [all-holder recovery policy](docs/principal-safety.md#fair-emergency-recovery). |

## Release Record

Before enabling public deposits, archive the exact reviewed commit, source hashes,
compiler/dependency settings, runtime bytecode, complete storage layout, deployed
addresses, roles, policy, proposal outcomes and successful acceptance evidence.
Record explicit sign-off for every [activation gate](docs/release-candidate.md#activation-gates).

The checked-in source layout is a research baseline, not a deployed upgrade
baseline. Future upgrades require a new compatibility and economic review.
