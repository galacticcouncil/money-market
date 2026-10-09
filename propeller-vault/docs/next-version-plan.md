# Next version: implementation plan

Branch `juicer-next`, stacked on #62 (`prop_carry`). Decisions are recorded in
the garden note (Propeller status, "next-version change list", 8–9 Oct). Nothing
deploys until review. The rename (Juicer, jETH/jtBTC, wjETH) is a separate PR
stacked on this one and lands before the Lark rollout (step 8 below). The UI
moves to a new PR on top of Jakub's rebrand branch (track G). The rollout target
is Lark 0, reforked from mainnet on the latest runtime with ICE (step 9).

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
  - Keep `beforeDeposit` for the allocation-integrity guard and `_repay(0, 0)`.
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
- New keeper flag (changed during implementation, 9 Oct): `deficitStop`, set
  only through `setDeficitStop(bool)` by the new `DEPOSIT_GUARDIAN_ROLE`.
  Deposits revert `DepositsArePaused` when `depositsPaused || deficitStop`.
  `pauseDeposits`/`unpauseDeposits` stay with `GUARDIAN_ROLE`, so a keeper can
  never lift a governance pause and needs no pause attribution.

Keeper:
- The deficit is computed off-chain each cycle:
  - source: `principalEquity` vs live equity (`negativeCarryBps`);
  - per vault: Main debt vs source backing (`equityOf − sourceValue + activeFunds`).
- Above `DEFICIT_STOP_BPS` (default 50) the keeper stops `pokeBorrow` and sets
  `deficitStop`. Below `DEFICIT_RESUME_BPS` (default 25, hysteresis) it clears it.
- Alert on every transition.

Tests:
- Deposits succeed during a sub-threshold deficit; the stop blocks them.
- The synthetic floor (`PrincipalNotFloored`) still holds.
- The deposit guardian can't pause, unpause governance's pause, configure or
  upgrade.
- The removed views live on as a test helper (`test/helpers/Deficit.sol`) that
  mirrors the keeper's check, so the old economic assertions still run.
- Keeper hysteresis unit tests.

## 2. Event-driven allocation

- `PropellerYieldAccounting`: transfers call `settle(from, to)` (`_settle` only);
  `checkpoint` (settle and `_allocate`) stays on deposit, `requestRedeem`,
  `_startUnwind`, `rebalance` and `sync`. Every allocation emits `Allocated()`.
- `prepareHarvest()` is renamed `sync()` (permissionless, returns the
  harvestable shares; the Harvester calls it too). The keeper calls it after each
  PRIME, ETH or tBTC oracle update it observes, and on a timer (`SYNC_EVERY`,
  default 1 h).
- Transfers check only the vault's own pause, so they no longer read the source
  (`paused()` asks the source for its emergency flag, which loads SubLoop's code).
- Fairness note: yield accrued between allocation events is credited to holders
  at the next event; transfers in between carry no allocation.
- Tests:
  - A transfer calls neither the source, Aave nor the Main debt ledger.
  - Allocation before vs after a transfer (documents the trade-off).
  - No newcomer captures pre-entry yield, since deposits still allocate first.
- Measure on Lark: transfer gas (target ≈0.2–0.3M, from ~0.92M).

## 3. Aave-style jETH

Changed during implementation (9 Oct): the plan's "claim the proportional funded
slice and burn units for its value" shifts every other holder's displayed
balance on someone else's transfer and needs equity/oracle reads in transfers.
Instead nobody materializes anything:

- Reward units stay the only claim on the fund, pro rata on both parts: funded
  vault shares F and reserved source shares S.
- `CollateralVault.balanceOf(a)` = wallet shares + `yieldAccounting.fundedOf(a)`
  (= units(a)/T × F). The fund's own balance is its wallet minus the attributed
  F; `walletOf(a)` returns the raw shares (accounting weights use it).
  Σ balanceOf = totalSupply up to lazy-unit rounding.
- A transfer up to the sender's wallet moves wallet shares only. A transfer
  beyond it also moves the units whose funded slice covers the rest, from sender
  to receiver (they carry their S claim too). No third party's balance changes,
  and nothing reads the source.
- **Exit fold:** `startExit` burns the exit's units (proportional to the
  escrowed shares, plus units committed at request time); their F slice moves
  from the fund into the redemption escrow before the entitlement is quoted, and
  their S slice follows the exit into the unwind as today. Nothing stays
  claimable after a full exit (the 0.22-share gap found 8 Oct).
- `requestRedeem(x)` with x above the wallet escrows the wallet and commits the
  units covering the rest to the request; `requestRedeem(max)` takes everything.
- Removed: `claimYield`, `claim`, `claimableShares`, `vestedShares`. Kept:
  `earnedAssets` (funded + pending, for the UI).
- Known effect: a holder's displayed funded slice can dip slightly at an
  allocation, because new units re-split F and S. The dip is bounded by the
  unharvested S; total value never drops. Integrations use wjETH.
- Size: CollateralVault headroom is the binding constraint; move logic into the
  accounting contract or `CompoundLogic` where needed.
  `test_runtimeSizesRemainDeployable` gates this.
- Tests:
  - Σ balanceOf = totalSupply (fuzz/invariant).
  - A transfer beyond the wallet carries the funded slice; no third party moves.
  - A full exit leaves the owner no units and nothing attributable in the fund.
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

- **Lark 0 (decided 9 Oct):** after the implementation and the rename, Lark 0 is
  reforked from mainnet and updated to the latest runtime (it must support ICE).
  The full chain-level setup then runs there with the track D bring-up: price
  mirrors, adapter, routes, market reserves, facilitator bucket, PRIME pool 143
  and bot inventory. The Lark scripts take the chain's RPC/WS from a profile.
- **Bots:** the same set as Lark 4 (replay, pools, markets/PRIME peg, depositor,
  mirror) plus two keepers.
- **Deposits:** the 100k depositor plan runs inside a 12-hour window. A loop
  checks progress and fixes what blocks it; anything it can't fix goes into the
  garden note.
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
9. Lark 0: refork from mainnet on the latest runtime (ICE), bring-up, bots,
   then the 100k deposits within 12 hours with a monitoring loop. Lark 4 stays
   up meanwhile.

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
├─ F rename prep (step 8): name mapping, rename script, dry run
│   └─ applied once 7 is done
├─ G UI: a new PR on Jakub's rebrand branch, against the planned ABI
│   └─ final ABIs ── after the rename
└─ H Lark 0 runbook: how to refork and upgrade it, researched in advance
    └─ executed after 8
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
