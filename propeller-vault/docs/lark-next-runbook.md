# New Lark bring-up for the next version

The next version deploys to **Lark 0** ("Lark 0 Hydration"), reforked from
mainnet after the rename; it needs a runtime with ICE (447 or later).
[Lark 4](lark-deployment-2026-10-07.md) keeps running from the same scripts. Every Lark script and bot takes its chain from a
profile in `scripts/propeller/lark-pins.mjs`. **This is a testnet procedure: no
step targets mainnet, and nothing here has been run with `--live` yet.**

## Profiles

| Profile | Chain | Files (`LARK_STATE_DIR`, default `/tmp`) |
| --- | --- | --- |
| `lark4` (default) | Lark 4, pinned genesis, scripts on `node4.lark`; the `4.lark` gateway stays the journal's identity, the keepers' fallback and the readiness WS, as before | `propeller-lark-20261007.json`, `propeller-lark-stack.json` |
| `lark0` | Lark 0 on `node0.lark`, for scripts, the journal and the bots; keepers fall back to the `0.lark` subway gateway as on Lark 4. Genesis and commit open until the refork (`LARK_GENESIS`, `LARK_COMMIT`) | `propeller-lark-lark0-20261009.json`, `propeller-lark-stack-lark0-20261009.json` |

- Select with `--profile=lark0` or `LARK_PROFILE=lark0`. The environment only
  fills a profile's open pins; it never overrides a pinned one, and a chain whose
  name is not a Lark is refused.
- After the refork, pin the genesis and the contracts commit in the `lark0`
  profile before the first `--live` run. Everything else is pinned, including
  the deployment id `lark0-20261009` that names the journal, manifest, stack and
  bring-up log.
- The shares are "Juicer ETH" `jETH` and "Juicer tBTC" `jtBTC`, the synthetic
  "Juicer Synthetic HOLLAR" `jsHOLLAR` with reserve tokens `aJSYNTH`,
  `vdJSYNTH` and `sdJSYNTH`: the names the rename gives mainnet.
- `PROPELLER_ARTIFACT_DIR` must point at the London build of the merged next
  version ([build commands](deferred-deployment-validation-2026-10-04.md#reproduce)),
  `PROPELLER_ADAPTER_ARTIFACT` at the pinned HydraAugustus build.
- The bots read the chain name and signers from the manifest (a manifest without
  them means Lark 4) and their endpoints from `LARK_RPC`/`LARK_WS`, which the
  Lark 0 stack sets.

## Bring-up from zero

```sh
export LARK_PROFILE=lark0 PROPELLER_ARTIFACT_DIR=… PROPELLER_ADAPTER_ARTIFACT=…
node scripts/propeller/lark-bringup.mjs --plan    # status from the journals, runs nothing
node scripts/propeller/lark-bringup.mjs           # dry-runs the next pending step
node scripts/propeller/lark-bringup.mjs --live    # runs pending steps in order
```

- A dry run validates only the next pending step, since later steps build on its
  live effects. `deploy`, `prices` and `discount` have no dry run.
- `--live` stops at the first step that fails or has not completed (for
  example `prime-cap` waiting for the pool 143 peg to converge).
  Rerun it to resume: each step's completion is read back from the deployment
  journals, and every step script is itself resumable.
- `--only=<step>` reruns one step, `--from=<step>` starts the scan later, and
  `--skip=<step,…>` goes past steps for a rehearsal only.
- Every run, skip and stop goes to `propeller-lark-bringup-<deployment>.json`.
  The `lark4` profile is refused except with `--plan`.

| Step | Script | Does |
| --- | --- | --- |
| `chain` | `lark-chain-check.mjs` (new, read-only) | runtime ≥ 447 with ICE (records the intent call indices), money-market reserves and oracles, pool 143 and its stored route, synthetic asset ID 5551 free |
| `prepare` | `lark-prepare.mjs` | isolated test accounts, contract deployer |
| `prime-pool` | `lark-prime-pool.mjs` (new) | pool 143 depth; under $100k it is topped up to $400k at its current ratio by one referendum; first HOLLAR mint creates the facilitator bucket (5M on the new Lark) |
| `deploy`, `wire` | `lark-deploy.mjs`, `lark-wire.mjs` | adapter, contracts, synthetic listing and reserve, wiring, execution lanes; shares `pETH`/`ptBTC` from the profile |
| `prices`, `discount` | `lark-prices-deploy.mjs`, `lark-discount-deploy.mjs` | price mirrors and zero discount, in the prices journal |
| `market` … `harvest-cap` | `lark-market-setup.mjs`, `lark-bootstrap.mjs`, `lark-approve-prime-cap.mjs`, `lark-protect-adapter.mjs`, `lark-routes-setup.mjs`, `lark-approve-harvest-cap.mjs` | as on Lark 4: mirrors installed, bot accounts, bootstrap, 6 bps PRIME and 100 bps collateral lanes, routes |
| `throughput` | `lark-prime-throughput.mjs` | PRIME entry and unwind lanes and source tranches: 2,500 a trade, 25,000 budget, 50/s refill, 6 bps cap and 60 s pacing kept |
| `sync` … `release` | `lark-mainnet-sync-*.mjs`, `lark-wrap-inventory.mjs`, `lark-stable-inventory.mjs`, `lark-release-deposits.mjs` | feeds, pools and replay inventory |
| `seed` | `lark-seed-bots.mjs --round=baseline` | everything the Lark 4 bots reported missing (rounds 463 and 464) |
| `params` | `lark-next-params.mjs` (new) | `harvestThreshold` 2e14, `fundReserve` 1,000 HOLLAR per vault from governance |
| `guardian` | `lark-deposit-guardian.mjs` (new) | `DEPOSIT_GUARDIAN_ROLE` on both vaults for both keepers and nothing else; it gates only `setDeficitStop`, while `pauseDeposits` and `pause` stay with governance |
| `ice` | `lark-ice-wiring.mjs` (new) | ICE for entries and routine exits: `configureIntents(300, 2)`, SubLoop `KEEPER_ROLE` for both keepers, `configureAsync` on the loop's entry and unwind lanes, and WETH on the loop's mapped account for the callback fee |
| `depositors`, `depositor-approve` | `lark-depositor-setup.mjs`, `lark-depositor-approve.mjs` | eight public test depositors with ~$100k of test ETH and tBTC, TVL caps to fit, u128 approvals |
| `manifest`, `stack` | `lark-manifest.mjs`, `lark-stack.mjs --keepers --depositor` | rerun on every live pass; the stack needs `KEEPER_IMAGE` and `BOT_IMAGE` by digest |

The outputs are config `propeller-lark0-20261009-manifest-v1` and stack
`propeller-lark0-20261009`.
Keepers get `QUOTE_DEPTH_BLOCKS` 3 and markets `PEG_BAND_BPS` 0.5. Lark 0 runs
the renamed images, `galacticcouncil/juicer-lark-keeper` and `juicer-lark-bots`,
by digest; Lark 4 keeps its `propeller-lark-*` digests. Creating the Swarm config
and stack stays a manual, stop-first step.

## Lark 0 timing

The $100k depositor plan has to land and lever within 12 hours:

- **Deposits:** one per vault every 600 s over a 10 h window (36,000 s), 60
  slots each. The schedule starts an hour after the stack is written
  (`DEPOSIT_DELAY_S`, or an absolute `DEPOSIT_START`), so it ends at 11 h.
- **Ramp:** every PRIME buy goes through the source's entry lane. The plan levers
  into ~400k of PRIME buys: 160 trades of 2,500 HOLLAR. Pacing allows one a
  minute and the 50/s refill restores a trade's budget in 50 s, so the lane
  carries 150k an hour. That is 2.7 h of trading against the deposits' ~40k an
  hour of buys; the loop keeps pace and finishes minutes after the last deposit.
  Lark 4 runs 1,000 a trade at a 10/s refill, budget-bound at 600 a minute: 11 h
  for the same buys.
- **Peg inventory:** the markets bot sells pool 143 back every PRIME the loop
  buys. It starts with 500k PRIME, 100k from `prepare` and 400k from the
  baseline seed round, 25% over the ramp. The refiller tops it back up to 500k
  once it holds under 250k, at most every 6 h.

There is no nurse and no Main cushion on the new chain: `lark-nurse.mjs`,
`lark-fund-main.mjs`, `lark-recap-source.mjs` and `lark-fund-exit.mjs` refuse
any profile but Lark 4.

## Tracks A and B

- **Deposit guardian:** `lark-deposit-guardian.mjs` refuses artifacts without
  `DEPOSIT_GUARDIAN_ROLE`, so `PROPELLER_ARTIFACT_DIR` must be the merged build.
- **ICE wiring** follows B's interfaces (checked against the sources by its
  test). `configureIntents` takes seconds (each deadline is
  `(block.timestamp + ttl) * 1000` ms, under a day), so five minutes is `300`.
  Drift is 2 bps, the keeper's own `QUOTE_DRIFT_BPS`. The lazy-executor charges
  each callback (~0.57 HDX, ~$0.004 in the spike) to the loop's mapped account
  in its fee currency: WETH for an EVM account by default, but its first token
  deposit while it holds no HDX switches it to that token, which is how the
  spike's probe came to pay in HOLLAR. The step pins the loop to WETH
  (`resetPaymentCurrency`) and funds 0.01 WETH and 10 HDX by governance; an
  unpaid callback is not queued, and keeper reconcile settles that intent.
- After A and B merge, recheck `lark-deploy.mjs` constructor and initializer
  arguments and `lark-wire.mjs` controller calls.
- The read-only checks and the depositor work on both contract versions: they
  probe the vault's `deficitStop()` and fall back to Lark 4's `ready()`,
  `isUnderfunded()` and `prepareHarvest()`. On the new chain readiness checks
  settled source accounting and a clear keeper deficit stop instead, `lark-observe`
  simulates `sync()`, and the depositor skips a vault while `depositsPaused` or
  `deficitStop` is set, logging the source's `negativeCarryBps`.

## After bring-up

- Refills: `lark-refill-bots.mjs --reports=<bot logs>` turns
  `inventory-refill-needed` rows and replay's skipped inputs into one seed
  referendum. Each bot and asset is topped up to a ceiling (pools and replay
  tokens to their setup levels) at most every 6 hours, within 90% of the deposit
  fuse or facilitator room. It never raises a fuse. It is a dry run unless
  `--live`; a refill interrupted after submission resumes on the next run.
- Verification on the new Lark follows the [plan](next-version-plan.md#7-verification).

## Lark 4 operators

Nothing changes. Scripts default to `lark4`, with the same journal, endpoints,
signers and labels. Its manifest and stack regenerate byte for byte; the stack
was checked against the deployed file. Lark 4 keeps its digest-pinned images,
and a new bot image also runs on its v3 manifest.

Tests: `node --test scripts/propeller/lark-*.test.mjs`; in
`propeller-vault/lark-bots`, `npm test`; and for the shared mainnet governance
helper, `node --import ./propeller-vault/looper/node_modules/tsx/dist/loader.mjs
--test scripts/propeller/next-governance.test.ts`.
