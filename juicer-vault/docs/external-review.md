# External review package

**For independent review | 4 November 2026 | PR #89, contracts at `585de4a`**

Start here for an independent security review of the Juicer launch candidate.
This document fixes the scope and the commit, describes the system and its
trust model, lists the invariants the design relies on and what the formal model
covers, records the known issues, ranks where to look first, and gives the
commands that rebuild and re-verify everything. Detail lives in the linked
documents. Several of them are dated; where one disagrees with the code at the
review commit, the code is authoritative ([dated material](#dated-material)).

## 1. Scope

| | |
| --- | --- |
| Repository | `galacticcouncil/money-market` |
| Branch | `juicer-headroom-exits`, PR #89 into `propeller` |
| Review commit | the head of PR #89. The contracts are as at `585de4a`; the commits after it change documentation, launch tooling and CI's production build, not `juicer-vault/src` |
| Solidity | solc 0.8.22, via-IR, optimizer 200 runs; the deployed build targets London |
| Dependencies | OpenZeppelin 4.9.6 (`bil-vault/lib` submodules), Aave core-v3 1.19.3 (`node_modules/@aave`) |
| Launch | one vault, jETH on GIGAETH (asset 4200, stableswap pool 4200's aETH/wstETH share), capped at 44.4 GIGAETH. A jBTC vault on tBTC (1000765) would need a later referendum of its own |

### Runtime contracts

`juicer-vault/src` at `585de4a`. nSLOC counts non-blank lines that are not
entirely comments.

| File | Role | nSLOC |
| --- | --- | ---: |
| `CollateralVault.sol` | per-collateral vault and share token: deposits, exits, claims, the Main position | 561 |
| `lib/SubLoopLogic.sol` | the loop's execution paths, by delegatecall: ramp, ICE intents, unwinds, safety de-lever | 541 |
| `JuicerMainDebt.sol` | per-vault Main debt ledger: debt units, exit cohorts, source batches, protocol reserve | 455 |
| `SubLoop.sol` | shared PRIME/HOLLAR loop: per-vault source shares, roles, configuration | 421 |
| `JuicerYieldAccounting.sol` | reward units, funded slices, harvest split | 338 |
| `lib/CompoundLogic.sol` | the vault's helper, by delegatecall: deposit admission, rebalance, exits (headroom and queue), compound | 330 |
| `ExecutionController.sol` | trade budgets, lane sizes, pacing, oracle-relative price caps, block-bound quotes | 296 |
| `JuicerFeeController.sol` | per-vault protocol fees and custody checks | 198 |
| `JuicerDiscount.sol` | HOLLAR interest discount for enrolled vaults and the loop | 193 |
| `lib/DcaDispatch.sol` | SCALE encoding of router sells and ICE intents for the `0x0401` dispatch precompile | 184 |
| `Harvester.sol` | splits loop carry across vaults and compounds each cut | 175 |
| `SyntheticToken.sol` | jsHOLLAR, the $1 synthetic collateral | 22 |
| **Total** | 12 files | **3,714** |

The eight interfaces in `src/interfaces/` add 174 nSLOC.

### Launch payload

Secondary scope: the governance referendum must do exactly what it says.

| File | Does | Check that |
| --- | --- | --- |
| `scripts/juicer/launch-deploy.mjs`, `launch-manifest.mjs` | deploy-only step: creates every contract with governance as admin; its one later call hands HydraAugustus to governance | no authority is left outside governance; constructor arguments match the manifest; the artifact checks hold |
| `tasks/proposals/juicer.ts` | builds the one Root referendum from the deploy manifest and the chain's state, including the treasury's buy of the GIGAETH it lacks | every call does what its label says, nothing is missing or extra, the order and batching are sound; the buy is bounded and planned only when needed |
| `scripts/juicer/next-governance.ts` | the launch values (`NEXT`, `LAUNCH`) and the planners the proposal and readiness share | the planned calls set exactly the [launch values](#launch-values) |
| `scripts/juicer/verify-readiness.ts` | read-only checks after enactment | a call the referendum reverted silently is caught |

### Out of scope

- Aave v3 core (pool, configurator, aTokens, debt tokens) and HOLLAR's GHO-style
  variable debt token.
- Hydration runtime and precompiles: dispatch `0x0401`, the ERC20 asset
  precompiles, router, stableswap, Omnipool.
- The ICE intent pallet, its lazy executor and solvers.
- HOLLAR and its facilitator.
- Oracle feeds (PRIME, HOLLAR, GIGAETH's composite source, the synthetic's $1
  source), including `contracts/CheckedOracle.sol` and `contracts/ManagedOracle.sol`.
  GIGAETH's source and pool 4200 are key [dependencies](#external-dependencies)
  all the same.
- The HydraAugustus swap adapter, built from a separate repository; its
  [assumptions](#external-dependencies) are listed.
- Lark testnet tooling and bots (`scripts/juicer/lark-*`, `juicer-vault/lark-bots`)
  and the UI.

The keeper (`juicer-vault/looper`) is context: everything it does is
permissionless or bounded on-chain ([roles](#3-roles-and-trust-model)).

### Changes since the last review

`git diff origin/propeller...585de4a -- juicer-vault/src`: 5 files, +147/−20.
The rest of #89 is launch tooling, keeper fixes, tests and formal re-pins.

| Commit | Change |
| --- | --- |
| `9abc7c2` | `SubLoop.setRebalanceBand` rejects a band whose delever point (max LTV − target gap + delever gap) is at or above the collateral's liquidation threshold |
| `4ed4f47` | `CompoundLogic.rebalance` reads the band in a try/catch and falls back to 0/500/300, so a new vault implementation works against a loop without bands |
| `2e3f82e` | headroom exits: `SubLoop.setExitHeadroom`/`exitHeadroom`, the appended `_exitHeadroom` mapping in `SubLoopStorage`, and `CompoundLogic._fromHeadroom`, `_headroomOpen` and `_fee` with the `HeadroomExit` event |
| `f82b818` | the `JuicerDiscount` constructor no longer reads or validates the synthetic's aToken, so the discount deploys before the reserve is listed |
| `d91480c` | `ExecutionController`: budget expiry removed (`Budget.expiresAt` and the `configureBudget` argument); budgets never lapse |

### Earlier reviews

All were internal; none is an independent audit.

- **#46, consolidated review at `e3e2c5a`:** 40 findings over 14 runtime files
  (the 12 above and the two oracle contracts). Each was re-checked with
  proof-of-concept tests: 26 confirmed, 13 partial, 1 invalid. #79, merged into
  `propeller` on 21 October, fixed 19 of them, including every finding still
  rated High after the re-check; their regressions are `test/AuditPr46*.t.sol`
  and `test/YieldFundTransfer.t.sol`. Its commit `633fb39` added policy fixes
  for gaps the review raised: the on-chain deposit admission bound, per-vault
  ownership of PRIME gifted to the Harvester, loss carries that restore
  written-down rewards before new units mint, and no loop deposits, unwind
  requests or pulls while an intent is in flight
  (`test/AuditPolicyResolution.t.sol`). The findings list is not in this
  repository, and neither is the status of the findings these changes do not
  cover; [section 5](#5-known-issues-and-accepted-risks) records the risks
  accepted for launch.
- **#53:** two independent passes over accounting and yield-source configuration.
- **#82, review at `b1479c8`:** one high finding, fixed in `a4a8895`: a settled
  but unclaimed withdrawal shrank later deposits' deployment credit. The
  follow-ups (band liquidation-threshold bound, band fallback, strict launch
  environment) are in #89.
- [`AUDIT.md`](../AUDIT.md) and [`x-ray/`](../x-ray/x-ray.md) are August
  snapshots of an earlier revision.

## 2. System overview

Juicer supplies a collateral deposit (GIGAETH at launch) to Hydration's Aave v3
market (Main), borrows HOLLAR against it and deploys the HOLLAR into one shared
leveraged PRIME position in the same market (the loop). Loop surplus is
harvested and converted back into the collateral. A $1 synthetic (jsHOLLAR)
supplied beside the deposit floors Main's health factor at any collateral
price, so while the floor is maintained a price fall does not liquidate the
deposit.

```text
user collateral (GIGAETH)
└─ CollateralVault (jETH) ─ Main position in Aave
   ├─ collateral aToken + jsHOLLAR (HF floor, never borrowed against)
   ├─ HOLLAR debt → JuicerMainDebt: active cohort, exit cohorts, protocol reserve
   │                └─ JuicerYieldAccounting: reward units, funded slices
   └─ borrowed HOLLAR → SubLoop: source shares per vault
      ├─ HOLLAR ⇄ aPRIME through ICE intents; the router for safety de-levers
      ├─ Aave: aPRIME collateral, HOLLAR debt (PRIME in isolation mode)
      └─ surplus PRIME → Harvester → vault.compound → collateral
         ├─ protocol fee → JuicerFeeController
         └─ Main interest → JuicerMainDebt
ExecutionController: size, budget, pacing and price caps on every swap
JuicerDiscount: HOLLAR interest discount on Main and loop debt
```

There are two debts: Main debt belongs to each vault, loop debt to the shared
strategy. Principal is denominated in the deposited token, not in USD. An unpaid
claim stays owed; nothing writes it off ([principal policy](principal-safety.md)).

### Contracts and upgradeability

| Contract | Deployment | Upgrade path |
| --- | --- | --- |
| CollateralVault | ERC1967 proxy (UUPS), one per collateral | `UPGRADER_ROLE` (governance). The implementation fixes `compoundLogic` as an immutable |
| SubLoop | ERC1967 proxy (UUPS) | `UPGRADER_ROLE` (governance). The implementation fixes `logic` (SubLoopLogic) as an immutable |
| CompoundLogic, SubLoopLogic | stateless delegatecall targets | only through a new implementation; `SubLoopLogic._authorizeUpgrade` reverts |
| JuicerMainDebt | one per vault; creates its JuicerYieldAccounting | none. `setMainDebt` binds it once, before the first share |
| Harvester, ExecutionController, JuicerFeeController, JuicerDiscount, SyntheticToken | plain contracts | none. A replacement needs governance rewiring; `setExecutionController` is one-time on the vault, the loop and the Harvester |

The proxies have no proxy admin, and both implementations disable their
initializers; `launch-deploy.mjs` checks both.

### Main flows

1. **Deposit** (`CollateralVault.deposit`): supplies collateral and mints shares,
   rounded up, with the donated rounding reserve covering the difference. No
   borrowing or swap. Reverts while paused, `depositsPaused` or `deficitStop`,
   while a Main resize or source accounting is pending, above the TVL cap,
   before governance's bootstrap deposit, or above the admission bound (item 9).
2. **Main borrow** (`CollateralVault.rebalance`, anyone): borrows toward the band
   target against the real collateral (Aave collateral less the synthetic),
   mints synthetic so `synthetic × LT ≥ debt` with a 0.5% buffer, and deposits
   the HOLLAR into the loop, where it waits as cash for the next entry. Above
   the delever point it unwinds enough of its active loop slice to return to the
   target, and the proceeds repay Main (`deleverTarget`). Waiting or unsettled
   exits suspend price-driven resizing; deposited and earned credit still deploys.
3. **Loop entry** (`SubLoop.pokeBorrowQuoted` for keepers, `pokeBorrow` for
   anyone): borrows down to `deployHfFloor` against current collateral and
   submits one ICE intent, HOLLAR → aPRIME. Its `minOut` is the largest of the
   oracle floor, the keeper's router quote less the solver's 1 bp and a 2 bps
   drift, and the controller's price cap. It settles on the executor's callback
   or on `reconcile()` once the fill or the refund shows in the balances.
4. **Harvest** (`Harvester.harvest`, anyone, through `ExecutionController.execute`):
   reconciles the loop, syncs every vault, withdraws each vault's owned surplus
   PRIME, and `compound` swaps it to collateral, takes the protocol fee,
   services Main interest and mints the rest to the reward fund.
5. **Bands** (`SubLoop.setRebalanceBand`): per vault, a target gap under the
   live max LTV plus relever and delever gaps; 0/500/300 by default.
6. **Exit request** (`requestRedeem`): escrows shares, and reward units beyond
   the wallet. They keep earning until the unwind starts.
7. **Exit start** (`startUnwinds`, anyone, FIFO, after the withdrawal delay):
   folds the exit's funded slice into the escrow, fixes `collateralOwed`, then
   takes the headroom path or the queue path (below).
8. **Settlement** (`pokeSettle`, anyone): pulls freed HOLLAR, allocates source
   cash and costs to claims in frozen batches (64 claims a call), repays a
   pending resize first, then settles up to 32 started exits FIFO. Each exit's
   debt is repaid from its own cash, and from the protocol reserve once its
   source claim is fully credited; collateral is released pro rata to
   repayment. An exit that is not fully repaid stops the loop and stays owed.
9. **Admission stop**: a deposit reverts when more than
   `admissionMaxDeficitBps` (250 at launch) of the vault's active Main debt is
   not covered by its loop equity, net of unconverted rewards, plus active cash,
   counting the fee due on unpaid interest.
   Keepers also set `deficitStop` above 250 bps and clear it below 200;
   governance and the committee hold `pauseDeposits`.
10. **Claims**: `claim(id, receiver, amount)` pays an exact amount, or
    everything settled with `type(uint256).max`. Anyone can deliver to the
    owner; only the owner can name another receiver. Later HOLLAR surplus goes
    to the original owner through `JuicerMainDebt.claimSurplus`.
11. **Floors**: `maintainPeg` (anyone) re-tops the synthetic as interest
    accrues. `deLever` (anyone) arms a loop repayment once the effective HF is
    below `targetHf` (1.05); `pokeRepay` then sells aPRIME through the router on
    the safety lane.

### Exits: headroom path and queue path

```text
startUnwinds(n): eligible requests, FIFO
└─ _startUnwind: fold the funded slice, fix collateralOwed (rounded up)
   └─ CompoundLogic.startExit: the exiter's loop slice = active + reward + fee units
      ├─ headroom open: on for the vault, LTV after the exit ≤ max LTV − gap,
      │  and the exiter's debt share exceeds its cash share
      │  ├─ slice value ≥ net debt → only the surplus unwinds; the debt stays
      │  │  └─ owner: all collateral at the next pokeSettle, the surplus in HOLLAR later
      │  └─ slice value < net debt, reserve ≥ queued exit debt + shortfall
      │     └─ the exit keeps only the shortfall; the protocol reserve pays it at pokeSettle
      └─ otherwise, the queue path
         └─ the whole slice unwinds; the exit cohort takes its debt units and cash
```

- `_headroomOpen` compares the vault's whole Aave debt, earlier exits' included,
  with (max LTV − gap) × the collateral left in Aave after this exit and after
  the collateral still owed to earlier exits.
- `_fromHeadroom` works at oracle marks: the slice `value` is
  `equityOf × slice / sharesOf`; the net debt `need` is the exiter's share of
  the active debt less its share of the active cash.
- Surplus: `unwind = slice − ⌈slice × need / value⌉` goes out through
  `requestUnwindProtected(unwind, 0)`. The exit cohort takes no debt and no cash,
  only that source claim, with the fee a full exit would pay (capped at the
  claim by the ledger).
- Shortfall: the exit cohort takes `⌈shares × shortfall / need⌉` of the
  exiter's pro rata debt units and cash, so its net debt is the shortfall, and
  no source claim. `_drawReserve` covers it at settlement.
- The holders who stay take over the slice and the net debt at the same value:
  neutral at the marks, at a higher LTV, and carrying the slice's later
  execution cost and any gap between the oracle and the market
  ([yield ownership](yield-ownership.md#headroom-exits)).

### External dependencies

| Dependency | Used for | Assumed |
| --- | --- | --- |
| Aave v3 market (core-v3 1.19.3) | Main and loop positions, `getUserAccountData`, reserve configuration bits (LTV 0–15, LT 16–31) | standard Aave behavior; the synthetic reserve stays listed with LTV 1%, LT 98%, borrowing off and a $1 source; PRIME is an isolation-mode reserve with debt-ceiling room |
| HOLLAR variable debt token | Main and loop debt, discount hooks | calls `JuicerDiscount.balanceOf` and `calculateDiscountRate` at every mint, burn and refresh and caches the result; Aave account data reads the undiscounted debt ([discount](main-borrow-discount.md)) |
| Stableswap pool 143 (PRIME/HOLLAR) and the router | loop entries and exits, harvest and servicing routes, the PRIME peg | enough inventory near the oracle; the launch fee is 1 bp |
| ICE intent pallet and its solvers | asynchronous entries and routine exits | a fill at or above `minOut` before the deadline, or a refund; the callback comes from the owner's account; liveness depends on solvers |
| Dispatch precompile `0x0401` | `DcaDispatch` SCALE calls with pinned indices (Router 67, Intent 98) | the runtime keeps those indices and call layouts; a change needs a new implementation |
| AaveOracle prices | NAV, allocation, exit values, swap floors | fresh and truthful; the contracts reject only a zero price; HOLLAR converts from USD at $1 |
| GIGAETH's oracle source (`0x32CC…9E90`, a `USDOracleAdapter`) | every GIGAETH mark: the vault's LTV and band, NAV, exit values, the harvest and servicing price caps | ETH/USD from DIA times a ten-minute EMA of pool 4200's share value in aETH (wstETH at a pushed wstETH/stETH rate); no layer checks staleness, and the adapter reports every block as fresh; the ETH/USD adapter's owner, an EOA that is also the DIA updater, can repoint the feed. The same source prices the money market's own GIGAETH reserve |
| Stableswap pool 4200 (aETH, wstETH) and the Omnipool's GIGAETH (asset 420) | GIGAETH's value and its share-value EMA; harvests buy and servicing sells GIGAETH along HOLLAR ⇄ Omnipool 420 ⇄ the money market's GIGAETH reserve; the referendum's treasury buy takes the same path | aETH and wstETH hold their ETH value; pool 4200 (about $3.85M) and the Omnipool's GIGAETH (about $2.07M) stay deep enough for 50 PRIME harvests and 0.02 GIGAETH servicing trades inside 100 bps; the reserve has cash for collateral claims (no GIGAETH borrowing today) |
| HydraAugustus | `compound` and Main interest sales (`ISwapper.sell`) | holds no funds between calls; governance owns it; the vault checks that the input is spent and the output clears its floor |
| Duster, asset registry, fee currency | custody accounts never dusted, shares registered as ERC20 assets, the loop's ICE callback fees paid in WETH | set by the launch referendum |

## 3. Roles and trust model

| Holder | Roles | Can | Cannot |
| --- | --- | --- | --- |
| Governance: the money market's pool admin, EVM origin `0xAa7e…Aa7e0`, reached from a Root referendum through `dispatcher.dispatchAsAaveManager` | `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `UPGRADER_ROLE` and `GUARDIAN_ROLE` on vaults and the loop; `DEFAULT_ADMIN_ROLE` on the synthetic, Harvester, fee controller, execution controller and discount; `RATE_ADMIN_ROLE` on the discount; owner of HydraAugustus | upgrade vaults and the loop; set every parameter and policy; grant roles; withdraw a protocol reserve (`withdrawReserve`); unpause; rewire. As pool admin it also controls the Aave reserves Juicer uses: fully trusted | move vault or loop assets without an upgrade: there is no sweep |
| Technical committee: `0x146a…b51b` in `launch-manifest.mjs` | `GUARDIAN_ROLE` on vaults and the loop; `RATE_ADMIN_ROLE` on JuicerDiscount | pause a vault; freeze the loop (`pauseEmergency`); stop and restart the loop's routes; pause and resume deposits; set the Main and loop discounts, 0–100% | unpause a vault or lift the emergency freeze; change fees or enrolment; upgrade; move funds |
| Keepers: `0xAF11…9898` and `0x8862…1E8a` (`LAUNCH.keepers`; `JUICER_KEEPERS` replaces them) | `KEEPER_ROLE` on the loop; `DEPOSIT_GUARDIAN_ROLE` on each vault | pass a router quote with `pokeBorrowQuoted` and `pokeRepayQuoted`, which can only raise the floor; set or clear `deficitStop` | anything else that anyone cannot |
| Deployer | none after the deploy, which is checked | one call after deploying: `HydraAugustus.transferOwnership(governance)` | — |
| Vaults | `VAULT_ROLE` on the loop; `MINTER_ROLE` on the synthetic | loop deposits, unwind requests and pulls; mint and burn the synthetic | — |
| Anyone | — | deposit; request; start eligible exits; settle; claim to the owner; harvest and rebalance through the controller with quotes that only tighten; `sync`; `maintainPeg`; `pokeBorrow` and `pokeRepay` at the oracle floor; `reconcile`; `deLever`; `clearCollateral`; fund reserves, positions and rounding; pay accrued fees to the recipient | name another receiver for someone's claim |

What an adversarial keeper, or anyone, can extract or block:

- **Price.** Loop trades fill no worse than 50 bps under the oracle-fair output
  (`dcaSlippagePpm` 5,000 and the PRIME lanes' cap), at most 2,500 HOLLAR or
  aPRIME a trade, refilling 10 a second with 60 s pacing. Harvest and servicing
  swaps: 1% (compound slippage and the collateral lanes' cap). The permissionless
  pokes and `ExecutionController.execute` already reach these floors;
  `KEEPER_ROLE` only allows a tighter one. The PRIME cap is wide on purpose: the
  keepers submit an entry intent only while their live router quote is within
  25 bps of oracle-fair (`ENTRY_MAX_COST_BPS` in the keeper; exits are not
  gated), but anyone's `pokeBorrow()` or `pokeRepay()` still opens an intent at
  the 50 bps floor.
- **Liveness.** An unfillable quote parks the loop's one intent until its 300 s
  deadline. Budget credit and pacing are spent at submit and not refunded on
  expiry. While an intent is in flight, loop deposits, unwind requests and pulls
  revert, which blocks `pokeSettle`, exit starts that unwind and borrowing
  rebalances.
- **Deposits.** `setDeficitStop(true)` closes deposits; clearing it cannot open
  them past the on-chain admission bound or a guardian's `pauseDeposits`.
- **Timing.** Whoever starts an eligible exit or opens the next intent fixes its
  values at that block's oracle marks.

## 4. Invariants and formal coverage

### Invariants

1. **Main floor.** After every borrow and deposit the synthetic covers Main
   debt, `syntheticSupplied × synthLT ≥ debt` (`PrincipalNotFloored`);
   `maintainPeg` restores the 0.5% buffer as interest accrues. The synthetic reserve has 1% LTV, and the vault sizes its
   borrowing off the real collateral only.
2. **Fixed collateral promise.** A started exit's `collateralOwed` never
   decreases; released collateral is at most `collateralOwed × repaid / debtShare`;
   settled but unclaimed collateral stays in `totalAssets` and
   `totalQueuedCollateral`.
3. **No dilution by others' entries or exits.** Deposits allocate yield before
   minting and round shares up; exits round `collateralOwed` up; the rounding
   reserve covers both, or the call reverts.
4. **Yield ownership.** Reward units are the only claim on the reward fund;
   transfers settle only their two holders; a newcomer gets no pre-entry yield;
   unconverted rewards are junior to the active Main debt.
5. **Cohort isolation.** Each exit cohort owns its debt units, cash, source
   claim and post-start interest; source cash and costs are allocated pro rata
   in frozen batches; the protocol reserve covers only an exit whose source
   claim is fully credited, and an unused draw returns.
6. **Admission.** Every successful deposit passed
   `⌈shortfall × 10000 / active debt⌉ ≤ admissionMaxDeficitBps`.
7. **Source shares.** Deposits and unwinds conserve loop shares; one vault cannot
   move another's; pending unwinds are liabilities outside live equity.
8. **Swap bounds.** Every swap enforces an oracle floor and, with the controller
   bound, its lane's size, budget, pacing and total shortfall; caller and keeper
   quotes only tighten.
9. **Intents.** At most one is in flight; its input counts at oracle value while
   away; the callback is accepted only from the loop's own account, for the
   current nonce, with `amountOut ≥ minOut`; a late callback changes nothing.
10. **Headroom exits.** Taken only while the vault's LTV after the exit stays at
    or under max LTV − gap and, for a shortfall, queued exit debt plus the
    shortfall fits the reserve. The holders who stay are no worse off at oracle
    marks (`test/KeeperOps.t.sol` asserts it).
11. **Bands.** No price-driven resize between the relever and delever points;
    borrowing never passes the band target; the delever point stays under the
    liquidation threshold.
12. **Authority.** No role outside governance, the committee's pause and rate
    roles, the keepers' quote and deficit-stop roles and the vaults' operating
    roles; implementations cannot be initialized; one-time bindings stay bound.

### What the Lean model proves

The model lives in `juicer-vault/formal` ([README](../formal/README.md),
[coverage record](../formal/SOLIDITY_PARITY.md)). It has no `sorry`; its axioms
are `propext`, `Classical.choice` and `Quot.sound`.

- **Real-number specifications:** the Main floor at any price (`floor_main_hf`,
  `never_liquidated_at_any_price`, `tick_safe`); `collateral_out_ge_in` under the
  `freedBacked` solvency premise; shared-loop share conservation and isolation;
  `_creditFreed` never over-credits; balances with funded earnings (the
  Σ `balanceOf` identity, exact transfers, no pre-entry yield, the exit fold).
- **Integer models of the current arithmetic:** rounding, the lazy index and its
  rescale bounds, Main cohorts, batches, vested fees and the reserve, the
  controller policy (`budgets_never_lapse`), the FIFO queue and exact-amount
  claims, Aave's half-up ray math, checked uint256 failure semantics.
- **Public-call machine** over a 33-opcode fixture dispatcher: every finite trace
  in the certified action domain preserves the combined custody, source-claim,
  cash and lifecycle invariant (`validSolidityTrace_invariant`,
  `validSolidityReachable_invariant`, `ordinaryTrace_fixture_ready`).
- **Configuration:** for every band SubLoop accepts, no resize inside the window,
  no borrowing past the target and the floor intact; every successful deposit
  passed the configured admission bound; discount rates stay within their caps.

### How Lean and Solidity are tied

`python3 check-runtime.py` is the CI gate. It:

- rebuilds the proofs and compares 2,061 Lean-generated cases (runtime,
  coverage, machine and configuration vectors) with the Solidity, in Foundry;
- checks `solidity-manifest.json` (hashes of 173 source, model and tooling files,
  `tasks/proposals/juicer.ts` included), `bytecode-manifest.json` (creation code,
  runtime templates, compiler settings, immutable and link references and
  selectors of 11 contracts) and the accounting storage slots;
- binds the compiled ASTs of `_shiftIndex`, vault `deposit`, `startUnwinds` and
  `pokeSettle`, accounting `beginHarvest` and `splitHarvest`, and 32 entrypoint
  guard prefixes to Lean (`solidity_bodies.py`, `solidity_guards.py`);
- replays public-call campaigns in three fixtures (baseline, market, loss and
  recovery) step by step in Lean from genesis, rejecting corrupted outputs; a
  1,176-call shared-intent history against the production SubLoop and Harvester;
  and 516 calls against Aave's `VariableDebtToken`.

### Gaps

- **Headroom exits are outside the model.** The stateful fixtures plug in a
  yield source without `exitHeadroom`, which reads as off, so every replayed
  exit takes the queue path. The headroom branch has Solidity tests only
  (`test/KeeperOps.t.sol`).
- Contract bodies are not proved equivalent: five stateful bodies and one helper
  are AST-bound, the rest rests on differential comparisons.
- The fixtures are single-vault at a 75% max LTV, with mocked pool, token and
  source behavior. Multi-vault harvest allocation and live SubLoop capacity are
  separate obligations.
- Upgrades, role administration and whole-protocol reentrancy are outside the
  proofs.
- Aave balances, oracle prices and ICE arrivals are premises. The 99% arrival
  heuristic does not authenticate the payer. Keeper and solver liveness, market
  losses and solvency are not derived.
- The HOLLAR debt token's discount accrual is not modeled.
- The bytecode pins are the Paris build. The deployed London build's runtime
  code is identical apart from the trailing metadata hash (compared for all 11
  contracts at `585de4a`). No deployed address is checked.
- The Verity bridge (`formal/bridge`) is an older simplified model.

## 5. Known issues and accepted risks

| Issue | Effect | Bound or status |
| --- | --- | --- |
| aToken prediction timing | JuicerDiscount deploys before the referendum's `initReserves`, bound to the address of the pool configurator's next creation. Any listing enacted between the deploy and this enactment shifts it, and a mainnet vote takes days; the discount then reads another token's balance for enrolled vaults | `juicer.ts` refuses to emit once the configurator nonce has moved; readiness checks `aSynthetic` against the listed aToken. Recovery: the committee sets the Main rate to 0, then governance redeploys and reinstalls the discount |
| Structural negative carry | entries cost pool fee, PRIME premium and slippage times loop leverage, booked as source loss before income arrives: about 50 bps to lever a deposit to the target, up to 90 bps seen on the testnets at full leverage | the admission bound closes deposits above 250 bps of active Main debt; readiness accepts negative carry under that bound; a newcomer can enter a deficit up to it |
| Keeper quote trust | see [roles](#3-roles-and-trust-model) | floors of 50 bps and 1%; quotes only tighten |
| Oracle staleness | NAV, allocation, exit values, the headroom take-over and swap floors all use oracle marks; the contracts reject only a zero price. A stale price moves value between exiters, depositors and holders by the mark error, and lets trades fill up to that error plus the cap away from the market in one direction (the other fails closed). PRIME pushes book yield in steps | the feeds are out of scope; dated evidence in [PRIME pricing](prime-pricing-replenishment.md) |
| Manual emergency accounting | no automatic all-holder settlement or yield extraction; a fair recovery needs a freeze, a per-holder snapshot, governance funding and possibly a scoped upgrade | policy in [principal safety](principal-safety.md#fair-emergency-recovery); FIFO and `fundPosition` are not a fair recovery |
| Bootstrap and dead shares | the first deposit must come from `ADMIN_ROLE`: governance deposits about $10 last in the referendum, and 1,000 dead shares go to `0xdead`. A donation to the vault is a gift to its holders | the bootstrap makes inflation uneconomic; deposits revert `InsufficientRoundingReserve` rather than charge rounding to holders |
| PRIME premium at launch | PRIME traded about 39 bps over the oracle in pool 143 on 3 and 4 November. The 50 bps cap lets entries fill at that premium, about 45 bps all in, and the loop's leverage turns that into roughly 2% of each deposit carried as source loss until carry repays it. The keepers hold their entries while a quote costs more than 25 bps (`ENTRY_MAX_COST_BPS`), but anyone's `pokeBorrow()` opens one at the 50 bps floor | operational: bring the pool near peg before launch; the referendum cuts its fee to 1 bp; the keepers' entry limit; the admission bound closes deposits above 250 bps of deficit |
| GIGAETH's composite oracle | the vault marks GIGAETH at DIA's ETH/USD times pool 4200's ten-minute share-value EMA. Nothing checks staleness (ETH/USD moved in steps of about 0.5%, up to 12.7 h apart, in the week to 3 November); one EOA can repoint the ETH/USD feed; a mark held 1% off for about 12 minutes takes about $0.9–1.3M of one-sided flow in a pool where little else trades | the feeds are out of scope; the money market's ETH and GIGAETH reserves carry the same assumptions; a wrong mark moves value as under oracle staleness above |
| aETH and wstETH depeg | GIGAETH is about half aETH and half wstETH. A stETH discount reaches the mark late: the wstETH peg moves at most about 0.03% a day, and its sanity check prices through pool 4200 itself, so the mark overstates GIGAETH while sellers drain the pool's aETH | jETH holds and pays GIGAETH and cannot protect against its depeg; the bands and the synthetic floor act on the overstated mark |
| Treasury buy bound | the referendum buys ~0.006 GIGAETH with HOLLAR, exact out, for at most 50% over the quote when the proposal was generated: at most about $7 overpaid. A buy that still fails leaves the transfer and the bootstrap failed as events | planned only while the treasury lacks the collateral; readiness flags an unbootstrapped vault; `JUICER_TREASURY_BUY_MAX_IN` pins the bound so a regenerated preimage matches |
| Execution cost allocation | realized loop sale losses are charged to the unwinding vaults' earned allowance; the excess stays a source liability of the holders who stay. Source batches split costs pro rata by claim, so a yield-rich exit shares costs with a principal-only exit | documented policy ([Main servicing](main-debt-servicing.md#execution-costs)) |
| Headroom exits shift risk | the holders who stay take the slice at oracle value: its later execution cost, the oracle-to-market gap and a higher LTV, up to max LTV − gap (0 at launch), until deposits or a delever restore the band. Governance can withdraw the reserve a started shortfall exit counts on | the LTV cap and the reserve check; outside the formal model |
| Exits suspend price resizing | any waiting or unsettled exit stops price-driven relevers and delevers for its vault; with a 7-day delay one holder can keep a small request open. GIGAETH moves with ETH: in simulation the vault's LTV passed 85% at some point on 36 of 200 one-year paths at the cap | yield and borrowing room only; the synthetic floor keeps Main HF ≥ 1 |
| A paused vault blocks every harvest | `Harvester.harvest` syncs every registered vault, and `sync` is `whenNotPaused`; removing a vault that still holds loop shares fails the share-sum check | liveness; one vault at launch |
| In-flight intents block other work | while the loop's intent waits (up to 300 s), `pokeSettle`, exit starts that unwind and borrowing rebalances revert; anyone can open the next intent when there is work. Borrowing rebalances are not charged to the entry budget, so HOLLAR can wait in the loop for entries | liveness, bounded by the deadline, the budgets and the band target |
| Silent referendum failures | `dispatchAsAaveManager` reports an EVM revert as an event, and later batches still run | readiness must pass before announcing; the rehearsals had none |
| Synthetic custody | jsHOLLAR transfers are unrestricted (only vaults mint it). After a Main liquidation the cached `syntheticSupplied` can exceed the live aToken balance | needs the floor to lapse with a ~90% collateral crash, or a frozen synthetic reserve |
| Loop safety floor | safety sales step only while the loop's HF stays at or above 1.005; below that, Aave's liquidation of the loop is the backstop. Loop losses reach Main backing after unconverted rewards | by design ([principal safety](principal-safety.md#protection-model)) |
| HOLLAR at $1 | USD8 values and HOLLAR amounts convert by 10¹⁰ throughout | relies on HOLLAR's fixed $1 price |
| Pinned pallet indices | `DcaDispatch` hardcodes Router 67 and Intent 98; a renumbered runtime breaks every dispatch until an upgrade | readiness checks the call indices `router.sell` 67/0, `intent.submitIntent` 98/0 and `intent.removeIntent` 98/1, and that `intent.cleanupIntent` exists; the encodings are pinned in `test/DcaDispatch.t.sol` |
| Discount cache | the debt token caches each borrower's discount between actions; a reverting loop refresh blocks `setDiscountBps`; a re-registered loop resumes its old rate; `balanceOf(loop)` returns `LOOP_TAG \| cap` | [discount](main-borrow-discount.md#cache-and-lifecycle) |
| Budgets never lapse | trading permissions have no automatic sunset | governance changes budgets by referendum |
| Collateral liquidity | `pokeSettle` withdraws released collateral from Aave and reverts while the reserve's cash is borrowed out | liveness |
| Rescale rounding | a seeded lazy rescale leaves one reward unit unclaimed | aggregate bound proved ([rounding](../formal/ROUNDING.md)) |

## 6. Suggested focus areas

In order of priority:

1. **Headroom exits: accounting and who bears what** (`CompoundLogic.startExit`,
   `_fromHeadroom`, `_headroomOpen`, `_fee`; `JuicerMainDebt.startExit`,
   `_drawReserve`).
   - The LTV test reads `getUserAccountData` (undiscounted debt, every
     collateral flag the vault carries) and values the synthetic at
     `syntheticSupplied`. Can donated collateral, a stale synthetic count or
     settled but unclaimed collateral open the path wrongly?
   - The shortfall branch scales the exit cohort with `⌈shares × shortfall / need⌉`.
     Does its net debt equal the shortfall in every rounding case, and is the
     reserve test (gross queued debt + shortfall ≤ reserve, nothing reserved)
     enough when the reserve is withdrawn or drawn by an earlier exit?
   - The reward and fee slices leave the reserve before `_fromHeadroom` runs. In
     the shortfall branch they stay in the vault's loop shares as active shares:
     is anyone diluted or paid twice? Does the protocol lose its fee units?
   - Surplus: `requestUnwindProtected(unwind, 0)` books the whole unwound value
     as earned allowance; the fee is computed at oracle value and capped at the
     claim. Check the fee against a queue-path exit of the same slice.
   - Interplay with rebalance (`exiting`), deposits refilling headroom, the
     delever point, oracle staleness and `pokeSettle` ordering.
2. **CompoundLogic delegatecall and storage boundaries.** The helper has no
   storage, reads the vault through its own external getters and returns values
   the vault writes. Look for writes or approvals that outlive a call,
   decoding of the returned tuples, state the vault changes before or after the
   delegatecall (`_startUnwind`, `rebalance`) and callbacks into the vault while
   its lock is held.
3. **Exit queue, settlement and claims.** `JuicerMainDebt.creditSource` frozen
   batches, `_settleSourceFee`, `_drawReserve` and the scaled-debt retry in
   `_repay`; the FIFO head stop in `pokeSettle`; `claim` share burns on partial
   and final claims; `claimSurplus`; the `pendingSourceAccounting` gates on
   deposits, starts and rebalances.
4. **ICE intents and keeper quotes.** `_outcome` thresholds against unsolicited
   transfers and aToken interest, `_settle`, the `execute` callback guard,
   `removeIntent`, in-flight valuation in `_totalEquity` and `_effectiveAccount`,
   routine exit sizing against `STEP_HF_FLOOR` while the input is away, and
   `consumeAsync`/`prepareAsync`/`recordAsync`.
5. **ExecutionController bounds.** `_available`, proportional pacing in `_charge`,
   the reverting `preview`/`simulate` path, quote binding in `execute`
   (block hash, age, deadline), safety lanes and `activeGroups`.
6. **Discount install.** The GHO hooks run inside every HOLLAR mint and burn:
   `balanceOf` must never revert for an unregistered borrower; check the predicted
   aToken, `_refreshAll` atomicity, `LOOP_TAG` and the 16-vault bound.
7. **Upgrade and storage safety.** The vault appends three slots after
   `__gap[29]` and the loop nine after `__gap[37]` (CI gates the loop's layout:
   43 entries preserved, 9 appended). Check the implementations' immutables,
   `_disableInitializers`, `_authorizeUpgrade`, that the delegatecall targets cannot
   be initialized or upgraded, and the one-time setters.
8. **Launch referendum correctness.** Step order and idempotent planning,
   weight packing and `scheduleAfter` offsets, treasury funding amounts, the
   treasury's GIGAETH buy (route, bound, planned only when the treasury lacks
   it, before the transfer that spends it), bootstrap last and its sizing in the
   collateral's decimals, `envNumber` strictness, the aToken re-check and
   readiness coverage.

## 7. Build, test and verify

Run from `juicer-vault` unless noted. CI pins Foundry v1.5.1 and Node 22.
Results and timings are from local runs at the head of PR #89 or at `585de4a`,
whose contracts it shares (Foundry 1.5.1, 32 cores), unless CI is quoted.

Setup, from the repository root:

```sh
git submodule update --init bil-vault/lib/forge-std bil-vault/lib/openzeppelin-contracts \
  bil-vault/lib/openzeppelin-contracts-upgradeable bil-vault/lib/solmate
npm ci --ignore-scripts
```

| Check | Command | Expected |
| --- | --- | --- |
| Production build, sizes | `forge build src ../bil-vault/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol --offline --evm-version london --skip test --skip script --sizes --out out-production --cache-path cache-production --build-info` | the [size table](#9-contract-sizes), plus the `ERC1967Proxy` that `launch-deploy.mjs` deploys; about 40 s cold. The 11 contracts are byte-identical to a build of `src` alone |
| Full regression | `forge test --offline --evm-version london --dynamic-test-linking -vv` | 86 suites: 801 passed, 0 failed, 13 skipped (eight opt-in campaign cases, two tuning runs, three fork or Verity setups). 22 minutes, nearly all compilation; the tests run in about a minute |
| Targeted: bands, headroom exits | `forge test --offline --evm-version london --dynamic-test-linking --match-path test/KeeperOps.t.sol -vv` | 27 passed; about 1 minute |
| Storage gate (root) | `node --test scripts/juicer/source-storage.test.mjs` and `node scripts/juicer/check-source-storage.mjs --artifact juicer-vault/out-production/SubLoop.sol/SubLoop.json` | 9 passed; `compatibleStoragePrefix: true`, 43 preserved, 9 appended |
| Formal gate (`formal`) | `lake exe cache get`, then `python3 check-runtime.py` | ends `Lean/Solidity runtime comparisons passed; source fingerprints and vector regeneration match`: axioms of 3,130 declarations, 129 formal tests, 10,499 replayed steps, the 1,176-call intent and 516-call debt-token replays, 18 #79 regressions. About 25 minutes cold in CI, 2 warm |
| Bytecode pins (`formal`) | `python3 check-bytecode.py` | 11 production contracts and 459 selectors match `bytecode-manifest.json` |
| Dispatch map (`formal`) | `python3 check-dispatch.py` | 33 opcodes, targets, selectors and action arguments match |
| Keeper (`looper`) | `npm ci && npm test`; `npx tsc --noEmit -p .` | 116 passed; type-checks |
| Governance planners (root) | `node --import ./juicer-vault/looper/node_modules/tsx/dist/loader.mjs --test scripts/juicer/next-governance.test.ts` | 24 passed |
| Launch manifest (root) | `node --test scripts/juicer/launch-manifest.test.mjs` | 4 passed |

Where the tests are (`test/`):

- yield ownership and accounting: `YieldEntryFairness`, `YieldFundTransfer`,
  `YieldCheckpointGas`, `AccountingSafety`, `PrincipalRounding`, `PartialClaim`,
  `ExchangeRateSettleWindow`;
- Main ledger, settlement and recovery: `MainDebt`, `HarvestMainDebt`,
  `SettleBatch`, `IntegrationWithdraw`, `RecoveryE2E`, `WithdrawalCooldown`,
  `DeleverQueueInterference`, `YieldFundedExecution`;
- loop, intents and execution: `IceIntents`, `ExecutionAsync`,
  `ExecutionControls`, `SubLoopUnwind`, `SubLoopUnwindSizing`,
  `UnwindSellPricing`, `DcaDispatch`, `Harvest`, `MultiVaultFlow`;
- bands, headroom exits and keeper paths: `KeeperOps`, `PermissionlessKeeper`,
  `NegativeCarryView`;
- configuration, roles and upgrades: `AdminConfig`, `AdminSourceControl`,
  `GuardianPause`, `SubLoopDeploy`, `SourceUpgradeCompatibility`,
  `SyntheticToken`, `SynthLtvZero`, `CollateralVaultDeposit`;
- fees and discount: `ProtocolFees`, `JuicerDiscount`, `CollateralVaultDiscount`
  and their fork variants;
- review regressions: `AuditPr46*`, `AuditPolicyResolution`, `ReviewFindings`;
- stateful invariants: `invariant/JuicerInvariant.t.sol`, ten invariants at 256
  runs of depth 50; formal parity: `formal/`, run by the formal gate.

`FOUNDRY_PROFILE=fast` speeds up iteration but is not the deployable build
([faster loops](../README.md#faster-loops)). Keep one set of flags per output
directory; switching flags recompiles everything. The fork suites skip unless
`DISCOUNT_FORK_RPC` (`JuicerDiscountFork`) or `FEE_FORK_RPC` (`ProtocolFeesFork`)
is set.

### Mainnet-fork launch rehearsal

`scripts/juicer/launch-rehearsal.mjs` runs the real deploy and proposal against
a local fork; its test fixtures (storage writes, public dev keys) refuse
non-local endpoints. Run the steps from the repository root.

1. Fork Hydration mainnet with `npx @galacticcouncil/chopsticks -c fork.yml`,
   which also serves `eth_*` on its port:

   ```yaml
   endpoint: <archive node wss endpoint>
   block: <recent finalized block>
   host: 127.0.0.1
   port: 18098
   build-block-mode: Manual
   import-storage:
     Parameters:
       RelayParentOffsetOverride: true
   ```
2. `node scripts/juicer/launch-rehearsal.mjs prepare`: whitelists and funds the
   dev deployer, keeper and user (the user with each launch collateral); instant
   blocks.
3. `JUICER_ARTIFACT_DIR=juicer-vault/out-production JUICER_ADAPTER_ARTIFACT=<HydraAugustus.json> RPC=http://127.0.0.1:18098 node scripts/juicer/launch-deploy.mjs <manifest.json> --fork`,
   with the pinned HydraAugustus build from its own repository. The `rebalance`
   and `smoke` steps read the same artifacts, so keep `JUICER_ARTIFACT_DIR` set.
4. `JUICER_MANIFEST=<manifest.json> JUICER_PLAN_OUT=<plan.json> RPC=http://127.0.0.1:18098 MARKET_NAME=Hydration HARDHAT_NETWORK=hydration npx hardhat juicer`;
   write the proposal hex (printed, and `proposal.hex` in the plan) to a file.
   The plan names the launch keepers and prices the treasury's GIGAETH buy
   with a dry run.
5. `JUICER_PLAN_OUT=<plan.json> node scripts/juicer/launch-rehearsal.mjs enact <proposal.hex>`:
   notes the preimage, submits, votes and passes the Root referendum with
   compressed periods, then mines every scheduled batch and reports each block's
   EVM calls and failure events; a clean run prints `ENACTED clean`.
6. Readiness: `eval "$(node scripts/juicer/launch-manifest.mjs <manifest.json> <plan.json>)"`
   with `WS`/`RPC` set, then
   `npx ts-node --transpile-only --compiler-options '{"module":"commonjs"}' scripts/juicer/verify-readiness.ts`.
   Loop equity passes after the first rebalance.
7. `node scripts/juicer/launch-rehearsal.mjs rebalance <manifest.json>`: the
   first keeper rebalance borrows against the bootstrap into the loop; run
   readiness again, which now passes in full.
8. `node scripts/juicer/launch-rehearsal.mjs smoke <manifest.json>`: a GIGAETH
   deposit, a keeper rebalance and entry intent, a headroom exit and two exact
   claims. The referendum's keepers have no keys on a fork, so the smoke's dev
   keeper gets the loop's `KEEPER_ROLE` through a fork-only governance call and
   loses it afterwards.

The report goes to `JUICER_REHEARSAL_REPORT`. Recorded at mainnet block
16,588,006 (4 November) with the tooling at the head of PR #89: 75 EVM calls
with 0 failures and the treasury's GIGAETH buy executed; readiness 158/159
before the first rebalance (loop equity) and 161/161 after it; smoke passed.
After the smoke's headroom exit drew a fraction of a cent from the protocol
reserve, readiness flags the reserve below 1,000 HOLLAR, as designed. On a fork
of block 16,588,875 the same deploy with the bound pinned regenerated the same
preimage.

## 8. Deployment and launch

[`../DEPLOYMENT.md`](../DEPLOYMENT.md) is the operator's runbook for these steps.

1. **Deploy only** (`launch-deploy.mjs`, resumable from its manifest). For the
   jETH launch it creates, in order: HydraAugustus, CompoundLogic, the vault
   implementation, SyntheticToken, SubLoopLogic, the SubLoop implementation and
   proxy, Harvester, JuicerFeeController (recipient: the Aave treasury),
   ExecutionController (60 s, 5 blocks), JuicerDiscount (against the predicted
   aToken), the jETH proxy and its JuicerMainDebt. Then it hands HydraAugustus to
   governance. It checks that the deployer holds none of the nine roles
   anywhere, governance holds every admin role and the committee the rate role,
   the proxies point at their implementations with no proxy admin, the
   implementations refuse `initialize`, the Main ledgers are not bound yet,
   every runtime matches its artifact outside immutables, and the deployer sent
   nothing unrecorded.
2. **One Root referendum** (`juicer.ts`). Each step plans only what the chain
   lacks, so a rerun after enactment proposes nothing:

   | Step | Calls |
   | --- | --- |
   | chain | pool 143 fee to 1 bp; the harvest and servicing routes the router lacks; the synthetic registered as ERC20 asset 5550; `initReserves` for it, then LTV 1%, LT 98%, 1% bonus, borrowing off, no supply cap, the $1 source; each share registered as a sufficient ERC20 asset |
   | custody | duster whitelist for the loop, Harvester, fee controller, each vault, Main ledger and yield accounting, and the adapter |
   | funding | collateral the treasury lacks bought first: an exact-out `router.buy` as the treasury, with HOLLAR along the router's stored route, the gap plus 20%, for at most 50% over the runtime's quote at planning (`LAUNCH.treasuryBuy`); from the treasury to the governance account: collateral for rounding and the bootstrap, HOLLAR for the reserves; the loop's fee currency reset to WETH, with 0.01 WETH and 10 HDX for ICE callbacks |
   | wire | loop tranches, route (`configureDca(222, 43, 1043, 143, 5000)`) and harvester; the Harvester's fee controller; per vault `MINTER_ROLE`, `VAULT_ROLE`, `setMainDebt`, the fee controller and registration, the Harvester, 100 bps compound slippage, the withdrawal delay; `GUARDIAN_ROLE` for the committee on the loop and vaults; the adapter's asset ids |
   | execution | budgets, pacing, lane limits, price caps (50 bps PRIME lanes, the unwind lane flagged safety; 100 bps collateral lanes), the four quote entrypoints, then `setExecutionController` on the loop, Harvester and vaults |
   | discount | JuicerDiscount installed as the HOLLAR debt token's discount token and rate strategy; per vault `setDiscountController` and `registerVault`; `registerLoop` with its cap |
   | next | keepers' `KEEPER_ROLE` and `DEPOSIT_GUARDIAN_ROLE`; harvest threshold; ICE and async lanes; bands; admission; headroom exits; the revenue mix |
   | reserve | `fundReserve` on each Main ledger |
   | rounding | each vault's rounding reserve, sized from the collateral's existential deposit |
   | open | governance's bootstrap deposit, last |

   The calls pack into batches of at most 40% of the scheduler's maximum block
   weight, by measured weight. Batch 0 runs at enactment and schedules each
   later batch with `scheduler.scheduleAfter`, one block each.
3. **Readiness** (`verify-readiness.ts`) before anything is announced, with the
   environment `launch-manifest.mjs` prints from the manifest and the plan.

### Launch values

All checked against the launch tooling at the head of PR #89 (contracts as at `585de4a`).

| Parameter | Launch | Contract default | Set in |
| --- | --- | --- | --- |
| PRIME route slippage (`dcaSlippagePpm`); PRIME lane cap | 5,000 ppm; 50 bps on-chain. The keepers enter only within 25 bps of oracle-fair (`ENTRY_MAX_COST_BPS`, keeper configuration) | 0: the floor is the oracle price | `juicer.ts` (`JUICER_SLIPPAGE_PPM`) |
| Loop tranches | 2,500 HOLLAR in, 2,500 aPRIME out | 0: uncapped | `juicer.ts` |
| Entry and unwind lanes | 2,500 a trade, 25,000 capacity, 10 a second, minimum 1 HOLLAR or 0.01 aPRIME, 60 s pacing | none | `LAUNCH.entry`, `LAUNCH.unwind` |
| Harvest lane | 0.01 to 50 PRIME a trade, 1,000 capacity, 1 a second, 100 bps | none | `LAUNCH.harvest` |
| GIGAETH servicing lane | 0.000001 to 0.02 GIGAETH a trade, 1 capacity, 0.001 a second, 100 bps | none | `LAUNCH.service` |
| Quote window | 60 s, 5 blocks | constructor | `launch-manifest.mjs` |
| jETH TVL cap | 44.4 GIGAETH | initializer | `launch-manifest.mjs` |
| Withdrawal delay | 7 days | 12 hours | `juicer.ts` |
| Admission bound | 250 bps | 50 bps | `NEXT.admissionMaxDeficitBps` |
| Protocol fee | 6,900 bps | 500 bps at registration | `NEXT.revenue` |
| Main and loop discounts | 4,000 and 9,000 bps; loop cap 5M HOLLAR | 0 and 0 | `NEXT.revenue`, `LAUNCH.loopCap` |
| Protocol reserve | 1,000 HOLLAR per Main ledger | 0 | `NEXT.reserveHollar` |
| Bootstrap | 0.005 GIGAETH, about $12 | none: the first deposit needs `ADMIN_ROLE` | `LAUNCH.bootstrap` |
| Treasury buy | the GIGAETH the treasury lacks for the bootstrap and rounding reserve, plus 20%, exact out with HOLLAR; at most 50% over the runtime's quote | — | `LAUNCH.treasuryBuy` |
| Headroom exits | on, gap 0 | off | `NEXT.exitHeadroom` |
| Band | 65/75/83%: gaps 500/1000/800 at GIGAETH's 80% max LTV (85% LT) | gaps 0/500/300 | `NEXT.band` |
| Harvest threshold | 0.02% of principal | 0.1% | `NEXT.harvestThreshold` |
| ICE | 300 s intents, 2 bps drift, both loop lanes async | 0: the router | `NEXT.intentTtl`, `NEXT.intentDriftBps` |
| Compound slippage | 100 bps | 0: fails closed | `juicer.ts` |
| Loop health factor | target 1.05, deploy floor 1.05, de-lever trigger 1.10 | initializer | `launch-manifest.mjs` |
| Pool 143 fee | 1 bp, from 4 | — | `NEXT.primePoolFeePpm` |
| Keepers | `0xAF11238c61D8D3E98b6e5A10c227e77DfD0D9898`, `0x8862A05A7d9aF0fdd7A0f8611c067E1f73921E8a` | — | `LAUNCH.keepers` |

## 9. Contract sizes

The production London build at `585de4a` (EIP-170 limit 24,576 bytes; initcode
limit 49,152):

| Contract | Runtime | Margin | Initcode |
| --- | ---: | ---: | ---: |
| CollateralVault | 24,555 | 21 | 24,976 |
| SubLoopLogic | 23,602 | 974 | 23,658 |
| SubLoop | 22,312 | 2,264 | 22,691 |
| CompoundLogic | 20,119 | 4,457 | 20,147 |
| JuicerMainDebt | 18,573 | 6,003 | 33,684 |
| ExecutionController | 15,285 | 9,291 | 15,709 |
| JuicerYieldAccounting | 13,506 | 11,070 | 13,842 |
| Harvester | 9,858 | 14,718 | 10,395 |
| JuicerFeeController | 8,960 | 15,616 | 9,402 |
| JuicerDiscount | 8,730 | 15,846 | 9,974 |
| SyntheticToken | 4,827 | 19,749 | 5,957 |

JuicerMainDebt's initcode embeds JuicerYieldAccounting, which it creates. A
Hydration transaction carries at most 2²⁴ gas, which is why the vault and the
loop take their helpers as constructor arguments instead of creating them.

## Dated material

These documents describe earlier revisions in places. Read them for rationale
and evidence; this document and the code take precedence.

- [`../README.md`](../README.md), [`release-candidate.md`](release-candidate.md),
  [`README.md`](README.md): test counts and parts of the router-era flow are
  historical; `release-candidate.md` is the September RC1 record.
- [`execution-controls-implementation.md`](execution-controls-implementation.md)
  is the PR #62 implementation record, updated for intents.
- [`main-borrow-discount.md`](main-borrow-discount.md) and
  [`protocol-fees.md`](protocol-fees.md) keep their standalone forge-script
  deployment steps; the launch uses the process above.
- [`../AUDIT.md`](../AUDIT.md), [`../x-ray/`](../x-ray/x-ray.md): August snapshots.
