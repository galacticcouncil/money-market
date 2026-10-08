# New Lark bring-up for the next version

The next version deploys to a different Lark chain, not chosen yet; it needs a
runtime with ICE (447 or later). [Lark 4](lark-deployment-2026-10-07.md) keeps
running from the same scripts. Every Lark script and bot takes its chain from a
profile in `scripts/propeller/lark-pins.mjs`. **This is a testnet procedure: no
step targets mainnet, and nothing here has been run with `--live` yet.**

## Profiles

| Profile | Chain | Files (`LARK_STATE_DIR`, default `/tmp`) |
| --- | --- | --- |
| `lark4` (default) | Lark 4, pinned genesis, scripts on `node4.lark`; the `4.lark` gateway stays the journal's identity, the keepers' fallback and the readiness WS, as before | `propeller-lark-20261007.json`, `propeller-lark-stack.json` |
| `next` | open until chosen: `LARK_CHAIN_NAME`, `LARK_GENESIS`, `LARK_RPC` (`LARK_WS`), `LARK_COMMIT` | `propeller-lark-next.json`, `propeller-lark-stack-next.json` |

- Select with `--profile=next` or `LARK_PROFILE=next`. The environment only fills
  a profile's open pins; it never overrides a pinned one, and a chain whose name
  is not a Lark is refused.
- Once the chain is chosen, pin its name, genesis, RPC and commit in the `next`
  profile, and rename the deployment id there if wanted, before the first
  `--live` run: the journal, manifest, stack and bring-up log are named after it.
- `PROPELLER_ARTIFACT_DIR` must point at the London build of the merged next
  version ([build commands](deferred-deployment-validation-2026-10-04.md#reproduce)),
  `PROPELLER_ADAPTER_ARTIFACT` at the pinned HydraAugustus build.
- The bots read the chain name and signers from the manifest (a manifest without
  them means Lark 4) and their endpoints from `LARK_RPC`/`LARK_WS`, which the
  `next` stack sets.

## Bring-up from zero

```sh
export LARK_PROFILE=next PROPELLER_ARTIFACT_DIR=… PROPELLER_ADAPTER_ARTIFACT=…
node scripts/propeller/lark-bringup.mjs --plan    # status from the journals, runs nothing
node scripts/propeller/lark-bringup.mjs           # dry-runs the next pending step
node scripts/propeller/lark-bringup.mjs --live    # runs pending steps in order
```

- A dry run validates only the next pending step, since later steps build on its
  live effects. `deploy`, `prices` and `discount` have no dry run.
- `--live` stops at the first step that fails, has not completed (for example
  `prime-cap` waiting for the pool 143 peg to converge) or is a placeholder.
  Rerun it to resume: each step's completion is read back from the deployment
  journals, and every step script is itself resumable.
- `--only=<step>` reruns one step, `--from=<step>` starts the scan later, and
  `--skip=guardian,ice` passes the placeholders for a rehearsal only.
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
| `throughput` | `lark-prime-throughput.mjs` | PRIME lanes 1,000 a trade |
| `sync` … `release` | `lark-mainnet-sync-*.mjs`, `lark-wrap-inventory.mjs`, `lark-stable-inventory.mjs`, `lark-release-deposits.mjs` | feeds, pools and replay inventory |
| `seed` | `lark-seed-bots.mjs --round=baseline` | everything the Lark 4 bots reported missing (rounds 463 and 464) |
| `params` | `lark-next-params.mjs` (new) | `harvestThreshold` 2e14, `fundReserve` 1,000 HOLLAR per vault from governance |
| `guardian` | `lark-deposit-guardian.mjs` | placeholder, track A |
| `ice` | `lark-ice-wiring.mjs` | placeholder, track B |
| `manifest`, `stack` | `lark-manifest.mjs`, `lark-stack.mjs --keepers` | rerun on every live pass; the stack needs `KEEPER_IMAGE` and `BOT_IMAGE` by digest |

The outputs are config `propeller-next-manifest-v1` and stack `propeller-next`.
Keepers get `QUOTE_DEPTH_BLOCKS` 3 and markets `PEG_BAND_BPS` 0.5. Creating the
Swarm config and stack stays a manual, stop-first step.

There is no nurse and no Main cushion on the new chain: `lark-nurse.mjs`,
`lark-fund-main.mjs`, `lark-recap-source.mjs` and `lark-fund-exit.mjs` refuse
any profile but Lark 4.

## Still placeholders

- **Track A:** `lark-deposit-guardian.mjs` grants `DEPOSIT_GUARDIAN_ROLE` on both
  vaults to both keepers as planned, and refuses to run until the artifacts have
  the role. Review it against A's final code.
- **Track B:** `lark-ice-wiring.mjs` is a stub for the controller's ICE actions
  and async lanes. Write it once B's interfaces settle.
- After A and B merge, recheck `lark-deploy.mjs` constructor and initializer
  arguments, `lark-wire.mjs` controller calls, and the read-only checks:
  `lark-readiness.mjs` and `lark-observe.mjs` read `ready()`/`isUnderfunded()`,
  and the bots' depositor reads `isUnderfunded()`; A removes both.

## After bring-up

- Depositor: `lark-depositor-setup.mjs`, `lark-depositor-approve.mjs`, then
  `lark-stack.mjs --keepers --depositor` with `DEPOSIT_START`.
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

Tests: `node --test scripts/propeller/lark-*.test.mjs` and, in
`propeller-vault/lark-bots`, `npm test`.
