# Juicer mainnet handover (formerly Propeller)

> Status 4 November 2026, release PR #46 (`propeller` → `hydration`).
> Companions: [`juicer-vault/DEPLOYMENT.md`](juicer-vault/DEPLOYMENT.md) is the runbook,
> [`juicer-vault/docs/external-review.md`](juicer-vault/docs/external-review.md) holds the scope,
> trust model, invariants and the full known-issues table. This page is the go-live checklist:
> what launches, in what order, what was rehearsed, what was decided and what stays open.

## Launch at a glance

| | |
| --- | --- |
| Vault | **jETH on GIGAETH** only; jBTC and other collaterals later, each by its own referendum |
| TVL cap | 44.4 GIGAETH |
| Withdrawals | 7-day delay; waiting shares keep earning until their unwind starts; requests can't be cancelled |
| Exits | headroom exits on (gap 0); otherwise the unwind queue |
| PRIME price cap | 50 bps on chain (loop floor and controller lanes); keepers enter only within 25 bps of oracle-fair (`ENTRY_MAX_COST_BPS`) |
| Lanes | 2,500 HOLLAR a trade at 10/s (25k budget); collateral lanes 100 bps; budgets never lapse |
| Loop | target HF 1.05, de-lever trigger 1.10; band 65/75/83 % LTV (GIGAETH max LTV 80 %) |
| Deposits | admission closes at 250 bps of negative carry; keepers stop at 250, resume at 200 |
| Revenue | 69 % of harvests to the treasury; HOLLAR discounts 40 % on Main debt, 90 % on loop debt (5M HOLLAR cap) |
| Reserves | 1,000 HOLLAR protocol reserve; rounding reserve from GIGAETH's existential deposit; 0.005 GIGAETH bootstrap by governance |
| Pool 143 | fee 4 → 1 bp |
| Keepers | `0xAF11238c61D8D3E98b6e5A10c227e77DfD0D9898`, `0x8862A05A7d9aF0fdd7A0f8611c067E1f73921E8a` |
| Committee | `0x146a…b51b`, the money market's emergency admin: pause (`GUARDIAN_ROLE`) and discount rates |

Defaults live in `scripts/juicer/next-governance.ts` (`LAUNCH`, `NEXT`), `scripts/juicer/launch-manifest.mjs` and
`tasks/proposals/juicer.ts`; the review package's launch-values table maps each to its contract default.

## Components

| Contract | Deployment | Upgrade path |
| --- | --- | --- |
| CollateralVault (jETH) | ERC1967 proxy (UUPS) | `UPGRADER_ROLE` (governance); the implementation fixes `compoundLogic` |
| SubLoop | ERC1967 proxy (UUPS), one shared loop | `UPGRADER_ROLE` (governance); the implementation fixes `logic` (SubLoopLogic) |
| CompoundLogic, SubLoopLogic | stateless delegatecall targets | only through a new implementation |
| JuicerMainDebt (+ JuicerYieldAccounting) | one per vault | none; bound once by `setMainDebt` |
| Harvester, ExecutionController, JuicerFeeController, JuicerDiscount, SyntheticToken | plain contracts | none; a replacement needs governance rewiring |
| HydraAugustus (swap adapter) | separate repo, handed to governance at deploy | owner = governance |
| Keeper (`juicer-vault/looper`) | two operators, Docker | image tag per release |

## Go-live checklist

**0. Preconditions**
- [ ] External review report received and its findings resolved or accepted.
- [ ] Pool 143 within the keepers' entry limit (PRIME ≲ 25 bps over the oracle; ~39 bps on 4 November). Above it entries simply wait.
- [ ] No other money-market listing will be enacted between the deploy and this referendum's enactment: the synthetic's aToken address is predicted from the pool configurator's nonce. `juicer.ts` refuses to emit if it moved; then redeploy JuicerDiscount and regenerate.
- [ ] Treasury holds ≥ ~1,050 HOLLAR, ≥ 0.01 WETH and 10 HDX (it buys its own GIGAETH inside the referendum).
- [ ] Deployer is a whitelisted contract deployer (it is) and funded for 13 creations.
- [ ] A clean checkout at the release commit, the production build (CI's `forge build src …/ERC1967Proxy.sol --evm-version london …`), and the gitignored `typechain`/`artifacts` the hardhat tasks import.

**1. Deploy** — `scripts/juicer/launch-deploy.mjs <manifest.json>` with `JUICER_DEPLOYER_KEY_FILE` (a path, never the key).
13 creations, then `transferOwnership(governance)` on HydraAugustus, nothing else. It refuses to finish unless the
deployer holds no role, governance holds every admin role, the proxies have no admin, implementations refuse
`initialize`, every runtime matches its artifact and the predicted aToken is recorded.

**2. Publish** — the manifest (addresses, code hashes, deploy transactions), verified sources (`scripts/juicer/verify-contracts.mjs`
submits each creation transaction to the explorer) and the external review.

**3. Build the proposal** — `npx hardhat juicer` with `JUICER_MANIFEST=<manifest.json>` and no overrides. It prints each
batch decoded, the single PROPOSAL hex and hash, the treasury buy's bound and the plan file. Publish hash, bound and decode.

**4. Submit** — note the preimage, submit on the Root track, place the decision deposit, vote.

**5. Enactment** — batch 0 runs on enactment and schedules four more on the next four blocks:
chain (pool fee, routes, synthetic listing) → custody, treasury buy and funding, wiring, execution policy →
discount install, keepers, ICE, bands, admission, headroom, revenue → reserve, rounding → governance's bootstrap.
`dispatchAsAaveManager` reports EVM reverts as events, so check every one of the five blocks for `ExecutedFailed`,
`BatchInterrupted`, `CallUnavailable` and overweight; a rerun of `juicer.ts` must print "nothing to propose".

**6. Readiness** — `scripts/juicer/verify-readiness.ts` with the environment `launch-manifest.mjs` prints. Green before
anything is announced; "positive loop equity" turns green after the keepers' first rebalance.

**7. Keepers** — start both operators on separate hosts and RPCs (`OPERATOR_COUNT=2`, `OPERATOR_INDEX` 0/1,
`OPERATOR_SLOT_SECONDS=60`, `OPERATOR_GUARD_SECONDS=15`, `ENTRY_MAX_COST_BPS=25`, `DEFICIT_STOP_BPS=250`,
`DEFICIT_RESUME_BPS=200`), funded with WETH for gas; alerts (`[ALERT]` lines) wired to the team channel.

**8. Announce** — publish the UI with the mainnet addresses. Raising the cap later is its own referendum.

## What was rehearsed

| Where | What | Result |
| --- | --- | --- |
| Mainnet forks (chopsticks), latest 4 Nov | deploy → one referendum → readiness → smoke (deposit, rebalance, ICE intent, headroom exit, exact claims) | 0 failures; readiness passes after the first rebalance |
| Lark 0, 2 Nov | GIGAETH-only through the launch process on a live chain | referendum 458 clean; readiness 159/159; keepers ~730 txs in 12 h with no alerts |
| Lark 4, 4 Nov (reforked from mainnet #16,589,287) | the exact mainnet payload, defaults only | referendum 448: 75 EVM calls, 0 failed; treasury buy executed; preimage byte-identical to the mainnet-fork dry run with addresses swapped |
| Lark 4, 30 Oct (jBTC) | $100k ramp, testers' withdrawals | headroom exits and partial exact claims on real requests |

## Decisions taken

| Date | Decision |
| --- | --- |
| 30 Oct | One root referendum after a deploy-only step; the deployer never holds admin |
| 31 Oct | Withdrawal delay 7 days; policy expiry removed from ExecutionController |
| 3 Nov | Launch with GIGAETH instead of tBTC (the tBTC bridge was paused); cap 44.4 GIGAETH; the referendum buys the treasury's GIGAETH |
| 3 Nov | Keepers and committee as above; the aToken prediction and the permissionless pokes stay as they are |
| 4 Nov | PRIME cap 50 bps on chain, keepers enter within 25 bps |
| 4 Nov | ETH/USD stays on DIA (one EOA writes the price and owns the adapter), as the money market already does |

## Open before mainnet

- External review.
- Pool 143 near peg.
- Deploy, then publish addresses, the regenerated preimage and the treasury buy's bound.
- Whether the wstETH rate check needs a reference outside pool 4200.

## Accepted risks (summary)

The full table with bounds is in the review package, section 5. The ones operators feel first:

- **ETH/USD trust:** DIA's updater EOA writes the price and owns the adapter behind GIGAETH (and the ETH reserve).
- **Structural negative carry:** entries cost fee, premium and slippage times leverage before income arrives; admission closes at 250 bps.
- **Permissionless pokes:** anyone can open an entry or exit intent at the 50 bps on-chain floor whenever there is work; the keepers' 25 bps limit only governs the keepers.
- **Keeper trust:** keepers choose quotes and timing within the caps; quotes only tighten floors.
- **Headroom exits shift risk** to the holders who stay, up to max LTV − gap, until deposits refill the room.
- **Manual emergency accounting:** a fair recovery needs a freeze, a per-holder snapshot and governance funding.
- **Silent referendum failures:** EVM reverts are events; readiness is the gate.

## Operating after launch

- **Watch:** loop HF and leverage, negative carry vs the 250 cap, unfilled or expiring intents, the PRIME premium in pool 143 and arbitrage refill, the reserve balance, keeper `[ALERT]` lines and gas.
- **Change parameters:** caps, lanes, fees and bands by referendum; the EconomicParameters track can act as the money market's admin (`dispatchAsAaveManager`) and is the fast path. TVL cap raises the same way.
- **Incidents:** the committee pauses a vault or freezes the loop (`GUARDIAN_ROLE`, `pauseEmergency`); keepers set the deficit stop. Upgrades only by governance.
- **Keepers:** rotate or add by governance (`KEEPER_ROLE`, `DEPOSIT_GUARDIAN_ROLE`); one key must never run on two hosts.

## Lessons that still apply

1. **Every batch reports success.** `dispatchAsAaveManager` turns EVM reverts into events; read the events of every scheduled block, then run readiness.
2. **Plan from one state.** A live node's eth RPC trails the substrate head; `juicer.ts` waits until both agree.
3. **Size the bootstrap in value, not units.** 0.0001 of a $2k asset is too small for the loop's first position; the launch bootstrap is ~$10 per collateral.
4. **Gas estimates move between estimate and inclusion** for intent submissions; the keeper adds 50 % there, 20 % elsewhere.
5. **Two keepers need one writer per slot.** Without guard bands they settled behind each other's intents; the guards and the pre-signing recheck stopped it.
6. **Arbitrage inventory is the loop's real limit.** The loop buys about 4.2× its TVL in PRIME through pool 143; on a testnet a 500k float ran dry in hours.
7. **Watch for state that can't resolve.** On a reforked testnet, mainnet referenda deciding at the fork block hold the root track forever; clear them first (testnet only).
8. **Slippage, not limits.** On the August lark-4 runs, swaps failed on slippage while the circuit breaker looked guilty; read the dispatch error before changing limits.
