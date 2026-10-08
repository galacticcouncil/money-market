# Next version: implementation plan

Branch `juicer-next`, stacked on #62 (`prop_carry`). Decisions are recorded in
the garden note (Propeller status, "next-version change list", 8–9 Oct). Nothing
deploys until review. The rename (Juicer, jETH/jtBTC, wjETH) is a separate PR
stacked on this one and lands before the Lark rollout (step 8 below). UI #4120
follows it.

## Scope

| # | Change | Decided |
| - | ------ | ------- |
| 0 | Protocol reserve, one-signature exit, keeper delivery (already on the branch) | approved |
| 1 | Underfunding checked off-chain only | 50 bps keeper stop, keeper pauses/unpauses deposits |
| 2 | Event-driven yield allocation, cheap transfers | transfers settle the two holders only |
| 3 | Aave-style jETH: balance includes funded earnings, nobody claims | funded only; pending shown in UI |
| 4 | ICE intents for entries, harvests and exits | router kept for safety de-lever |
| 5 | Keeper: no standalone interest servicing, quote depth, deficit stop, ICE flow | — |
| 6 | Deployment parameters | harvest threshold ~0.02%, reserve 1,000 HOLLAR/vault, PRIME trade size to pool depth |

Dropped: earn-after-deploy (worth ~$1 per $100k deposit).
Parked for the rates topic: fee/discount mix, loop discount, entry cost from yield, band width, share-price jETH.

## 1. Underfunding off-chain

Contracts:
- `CollateralVault.deposit`:
  - Drop `isUnderfunded()`.
  - Keep the `deleverTarget != 0` guard, renamed `DeleverPending`.
  - Keep `beforeDeposit` only for `_repay(0, 0)`.
- `CollateralVault.isUnderfunded`, `CompoundLogic.isUnderfunded`: remove. Also
  remove the `Underfunded` revert in `CompoundLogic.rebalance`.
- `PropellerMainDebt`:
  - Remove `activeUnderfunded`, `ready` and the `UnfundedInterest` revert in
    `beforeDeposit`.
  - Keep `pendingSourceAccounting` (allocation integrity).
  - Keep `fundReserve`/`withdrawReserve`/`_drawReserve` for realized exit
    shortfalls.
  - Remove the reserve-as-backing lines added in `f0d3ebf` (the guards they fed
    are gone).
- New `DEPOSIT_GUARDIAN_ROLE` on the vault, allowed only `pauseDeposits` and
  `unpauseDeposits`. It is granted to the keepers. `pause()` stays with
  `GUARDIAN_ROLE` and `unpause()` with admin.

Keeper:
- The deficit is computed off-chain each cycle:
  - source: `principalEquity` vs live equity (`negativeCarryBps`);
  - per vault: Main debt vs source backing (`equityOf − sourceValue + activeFunds`).
- Above `DEFICIT_STOP_BPS` (default 50) the keeper stops `pokeBorrow` and
  calls `pauseDeposits`. Below `DEFICIT_RESUME_BPS` (default 25, hysteresis)
  it calls `unpauseDeposits`, but only if it was the keeper that paused.
- Alert on every transition.

Tests:
- Deposits succeed during a sub-threshold deficit.
- The synthetic floor (`PrincipalNotFloored`) still holds.
- The deposit guardian cannot `pause()` or upgrade.
- Keeper hysteresis unit tests.

## 2. Event-driven allocation

- `PropellerYieldAccounting`: split `checkpoint(from, to)` into
  - `settle(from, to)`: `_settle` only. Used by `_beforeTokenTransfer`.
  - `checkpoint`: settle and `_allocate`. Used by deposit, `requestRedeem`,
    `_startUnwind`, `rebalance`, `compound`, `prepareHarvest` and `pokeSettle`.
- New permissionless `sync()` on the vault, calling `yieldAccounting.checkpoint(0, 0)`.
  The keeper calls it after each PRIME, ETH or tBTC oracle update it observes,
  and on a timer (`SYNC_EVERY`, default 1 h).
- Fairness note: yield accrued between allocation events is credited to holders
  at the next event; transfers in between carry no allocation.
- Tests:
  - A transfer does not call the source or Aave (gas assertion).
  - Allocation at events matches the old per-transfer allocation within one
    event interval.
  - No newcomer captures pre-entry yield, since deposits still allocate first.
- Measure on Lark: transfer gas (target ≈0.2–0.3M, from ~0.92M).

## 3. Aave-style jETH

- **Claim semantics:** `claim` currently lets an early claimant take more than
  a proportional funded slice. Change it to exactly the proportional funded
  slice: `units/totalUnits × funded` plus `vested`. Burn units for that value.
  This makes balances additive.
- `CollateralVault.balanceOf(a)`:
  - for holders: `super.balanceOf(a) + yieldAccounting.fundedSharesOf(a)`;
  - for the reward fund itself: `super.balanceOf(fund) − yieldAccounting.heldForHolders()`.
  - Invariant: Σ balanceOf = totalSupply.
- **Claim-on-touch:** in `_beforeTokenTransfer` when `from` is a holder, and in
  `requestRedeem` and `_startUnwind`, materialize `from`'s funded shares into its
  wallet first (fund → holder `Transfer` event). `requestRedeem(max)` becomes
  ordinary.
- **Exit fold:** `startExit` returns the owner's newly vested funded shares.
  `_startUnwind` moves them from the fund into the redemption escrow before
  quoting the entitlement, so nothing is left claimable after a full exit (the
  0.22-share gap found 8 Oct).
- Remove the `claimYield` external (and the UI claim button). Keep a view
  `earnedAssets` with pending/unconverted yield for the UI.
- Size: CollateralVault has 432 B free today. Removing `isUnderfunded` and
  `claimYield` frees some; move balance and materialize logic into
  `CompoundLogic` or the accounting contract if needed.
  `test_runtimeSizesRemainDeployable` gates this.
- Tests:
  - Σ balanceOf = totalSupply (fuzz/invariant).
  - A transfer carries the sender's funded earnings, and the receiver gets none
    of the sender's pre-transfer yield.
  - A full exit leaves `claimableShares == 0`, including cooldown earnings.
  - A partial redeem of more than wallet shares works.
  - Protocol fee shares are unaffected.

## 4. ICE intents

From the spike (`scripts/propeller/ice-spike`, 8 Oct): a contract submits via
dispatch `0x0401`. The solver resolves next block and pays output to the owner
at AMM output − 1 bp. The lazy-executor then calls
`execute(owner, intentId, assetIn, amountIn, assetOut, amountOut, data)` with
`msg.sender == tx.origin == owner`, which must return its selector. Expiry
returns funds via `cleanup_intent`, with no callback.

Contracts:
- `DcaDispatch.submitIntent` / `removeIntent`: SCALE-encode
  `intent.submitIntent({Swap{asset_in, asset_out, amount_in, amount_out, partial:false}},
  deadline, Forward{contract: self, data})`. Pallet and call indices come from
  runtime metadata, pinned with a test.
- **SubLoop entry (deploy and `pokeBorrow`):**
  - Borrow, then submit a HOLLAR→aPRIME intent.
  - `minOut = max(oracle × (1 − dcaSlippage), keeperQuote − 1 bp − drift)`.
  - Store `pending[lane] = {nonce, amountIn, minOut, deadline, kind}`.
  - Callback `execute` checks `msg.sender == address(this) == owner`, the
    nonce in `data`, `assetOut` and `amountOut ≥ minOut`. It then enables
    collateral, records shares and clears pending.
- **Reconcile** (permissionless, after the deadline or on a missed callback),
  using balance deltas with one in-flight intent per lane:
  - output arrived: treat as resolved;
  - input back: treat as expired;
  - otherwise wait.
  The keeper calls signed `cleanup_intent` if the off-chain worker is slow.
- **Equity:** in-flight input counts in `totalEquity`/`equityOf` at oracle
  value. HF math treats the in-flight HOLLAR as debt-backed cash. The next
  ramp step waits for resolution.
- **ExecutionController:** two-phase. `consume` at submit stores the lane's
  `minimum` and `pending`. A new `recordAsync(lane, nonce, output)` is called
  from the callback or reconcile. Budget, pacing and price caps are unchanged.
- **Harvest:** `Harvester.harvest` hands PRIME to each vault as today. The
  vault's `compound` submits the PRIME→collateral intent as its own owner, and
  its `execute` callback finishes the compound on the output.
  `beginHarvest`/`splitHarvest` move to the callback, and pending harvest PRIME
  counts in the fund NAV.
- **Exits:** `_sellForUnwind` uses ICE for normal unwinds. The safety path
  (`deleverDebtTarget != 0`, `deLever`) keeps the synchronous router.
- **Emergency:** on `pauseEmergency`, the keeper removes pending intents
  (`removeIntent`) and reconciles.

Keeper:
- For ICE actions, drop the blockhash/quote binding. Compute `keeperQuote`
  from a router dry run and pass it as a parameter. The contract floors it at
  the oracle cap.
- Track pending intents from `IntentSubmitted` and reconcile on timeout.
- Alert if the solver is quiet for N blocks.
- Optional router fallback for entries after M failed intents
  (`ICE_FALLBACK`, default off).

Tests:
- Mock dispatch precompile (`vm.etch` at `0x0401`) that records the intent.
  The test resolves it by transferring output and calling `execute`.
- Cases:
  - resolve;
  - partial-free fill below `minOut` rejected;
  - missed callback, then reconcile;
  - expiry, then reconcile;
  - wrong sender/nonce/asset rejected;
  - pause with pending;
  - harvest async;
  - unwind async;
  - safety de-lever stays synchronous.
- New Lark: real solver end to end.

## 5. Keeper (beyond 1 and 4)

- Remove periodic Main interest servicing (`pokeSettle` only for queue work).
  Interest is paid from harvest servicing and at exits.
- `QUOTE_DEPTH_BLOCKS` defaults to 3 for any remaining router action.
- Delivery (`deliver`) stays. Add a `sync()` cadence.
- Remove the `ready()` dependency (gone with 1).

## 6. Deployment and parameters

- **New Lark, not Lark 4 (changed 9 Oct):** the next version deploys to a
  different Lark chain, so chain-level setup runs again there: price mirrors,
  adapter, routes, market reserves, facilitator bucket, PRIME pool 143 and bot
  inventory. The Lark scripts take the chain's RPC/WS instead of assuming
  node4. The chain needs a runtime with ICE (447 or later, as on Lark 4).
- **Lark 4 keeps running for a while** alongside, on its digest-pinned images,
  so new builds don't touch it.
- **Parameters:**
  - `setParams(…, harvestThreshold = 2e14)` (~0.02%);
  - `fundReserve(1000e18)` per vault;
  - `DEPOSIT_GUARDIAN_ROLE` granted to the keepers;
  - controller ICE actions and async lanes;
  - mainnet PRIME trade size set from pool 143 depth at deploy;
  - Lark keeps 1,000/trade.
- No nurse and no Main cushions.

## 7. Verification

- Forge: per-change tests above, invariants (floor, Σ balanceOf, share
  conservation) and the full suite. Size gate.
- Keeper: node tests for deficit hysteresis, ICE pending/reconcile and the
  sync cadence.
- Lean (`formal/`):
  - `Redemption.lean`: escrow including folded vested shares; share
    conservation.
  - `SubLoop.lean`: in-flight intent amounts in equity and in the de-lever
    precondition.
  - Floor and peg proofs are untouched.
  - Rerun the bridge parity tests.
- New Lark: depositor, ramp, an exit round, a simulated collateral
  drop (oracle override), ICE resolution and gas measurements.

## Order of work

1. Underfunding removal and deposit guardian.
2. Event-driven allocation and `sync()`.
3. Claim semantics, then Aave-style jETH and exit fold.
4. Keeper deficit stop, pause, servicing removal and sync.
5. ICE: dispatch encoding and controller async, then SubLoop entry, then
   harvest, then exits, then keeper ICE flow.
6. Deployment scripts for the new Lark, including the full chain-level setup.
7. Docs, Lean and parity.
8. Rename PR, stacked on this one: Propeller → Juicer everywhere, shares
   jETH/jtBTC. Rename only, no logic. It goes before the rollout because the
   deploy scripts set the share symbols (`pETH`/`ptBTC`) at initialization.
9. Rollout on the new Lark after review, on the final names. Lark 4 stays up
   meanwhile.

Each step is its own commit with tests and a size check.

## Parallel tracks

Steps 1–3 stay in order: they all edit `CollateralVault` and share its EIP-170
headroom. The rest runs beside them, each track in its own worktree off
`juicer-next`.

```
now
├─ A core contracts, in order: 1 underfunding → 2 event allocation → 3 jETH + exit fold
├─ B ICE contracts (DcaDispatch, ExecutionController, SubLoop; no overlap with A)
│   dispatch encoding + controller async → SubLoop entry → ICE exits
│   └─ ICE harvest (vault callback) ── waits for A3, it edits CollateralVault
├─ C keeper (step 4): deficit stop + pause, servicing removal, sync cadence
│   └─ ICE pending/reconcile ── once B's interfaces settle
├─ D new-Lark tooling (step 6): scripts take the chain's RPC/WS, full chain
│   setup, automatic bot inventory refills
│   └─ final parameters ── from A and B
├─ E Lean (step 7): Redemption (exit fold), SubLoop (in-flight intents), from
│   this plan's semantics
│   └─ parity tests ── once A and B are merged
└─ F rename prep (step 8): name mapping, rename script, dry run
    └─ applied once 7 is done
then: merge A → B → C → D, parameters (6), docs + parity (7), rename (8), new Lark (9)
```

- **Critical path:** A (1 → 2 → 3) → ICE harvest → 6 → 7 → 8 → 9.
- **Merging:** in the order A → B → C → D, with the size gate and the full suite
  after each merge. Shared test helpers are the main conflict point, so changes
  to them land in A first and the other tracks rebase.
- **Review stops:** after A3 (together with B's entry and exits), and after the
  ICE harvest merge.
- **Non-code, can start now:**
  - pick the new Lark (needs ICE, runtime 447 or later);
  - ask the PRIME oracle relay operator to push every NAV change;
  - ask the ICE team about refunding the 1 bp haircut.

## Risks and open technical points

- **Size:** CollateralVault EIP-170 headroom is the binding constraint for
  step 3.
- **ICE callback** runs as a best-effort OCW transaction. Reconcile must
  never double-count, so state is keyed by lane nonce with balance-delta
  checks.
- **ICE pallet and call indices** can change with runtime upgrades. Pin them
  in tests and check them at deploy.
- **Solver liveness:** ICE resolution depends on Hydration's off-chain
  worker. The keeper alerts on stalls; the router fallback is optional.
- **Claim semantics change** (proportional funded slice) alters who bears
  unconverted-source exposure after partial claims. Proving it fair needs
  the invariant test.
