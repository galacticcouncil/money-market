# Lark deployment — 7 October 2026 (fresh fork)

Lark 4 was re-forked from Hydration mainnet and the PR #62 contracts, including
the review fixes, were deployed fresh. Keepers and market services run in the
`propeller-oct2026` [Swarm stack](https://swarmpit.lark.hydration.cloud); the
[UI preview](https://deploy-preview-3978--edge-hydra-app.netlify.app/strategies/propeller)
reads this deployment. **This is a testnet rehearsal, not a mainnet release or
an APY claim.** The [7 October evidence](evidence/lark-2026-10-07/) holds the
sanitized journal, governance referenda, readiness log and checksums. It
supersedes the [5 October deployment](lark-deployment-2026-10-05.md), whose
chain no longer exists.

| Item | Value |
| --- | --- |
| Fork point | mainnet block 15,484,030, `0x60a4017c…6d99`, runtime 447 |
| Genesis | `0x0a1fba23f7897cb5cbb3289db93ab605774565149b0c87033b4f2af817c9f96c` |
| EVM chain ID | 222222 |
| Contracts source | `db0799c` (London build) |
| ETH vault | `0x3a1c0fa2f877c84d2930e59637c111a31878dcdf` |
| tBTC vault | `0x7b200b8c8a5ffd7720a48b0cb5a7f9fc6a512578` |
| Source | `0x5b153c8e24ca62436ef836a1f179dd8ade2d5acd` |
| Controller | `0xa64e418978482d5de91717cf6c77e1f40105f2ab` |
| Harvester | `0xe0983cedd797b38090e6dcde54af88aa6eb22edc` |
| HydraAugustus | `0x538d2755b5fb9a4f7c5769bdcf5103e569d6e241` (`aave-debt-swap@ddc883e`) |
| Keeper image | `galacticcouncil/propeller-lark-keeper@sha256:a3255dd2…` (`db0799c`) |
| Bot image | `galacticcouncil/propeller-lark-bots@sha256:032cb274…` (`9d81c0f`) |
| UI | PR #3978, `cccd9effe` |

Later commits on the branch only trim comments and dead code. Contract ABIs,
storage layouts and runtime bytecode are unchanged apart from the metadata
hash, so the deployed contracts and images still match the reviewed code.

## Procedure

Pins live in `scripts/propeller/lark-pins.mjs`; a future reset changes only
that file and keeps every genesis check. With `PROPELLER_ARTIFACT_DIR` (London
build) and `PROPELLER_ADAPTER_ARTIFACT` (HydraAugustus) set, run in order with
`--live`: `lark-prepare`, `lark-deploy`, `lark-wire`, then `lark-prices-deploy`
and `lark-discount-deploy` with `PROPELLER_LARK_RESULT` set to the prices
journal, then `lark-market-setup`, `lark-bootstrap`, `lark-approve-prime-cap`,
`lark-protect-adapter`, `lark-routes-setup`, `lark-fund-main` and
`lark-approve-harvest-cap`. For mainnet sync, run `lark-mainnet-sync-setup`,
`lark-mainnet-sync-inventory` and `lark-wrap-inventory`; run
`lark-release-deposits` only if a test mint was parked. Finally `lark-manifest`
writes the bot config and `lark-stack --keepers` the compose.

A fresh mainnet fork differs from the July-based chain in four ways:

- HydraAugustus does not exist; `lark-deploy` deploys the pinned adapter, maps
  the four asset IDs and hands ownership to governance.
- Mainnet stores no PRIME↔ETH or PRIME↔tBTC route, and PRIME is not in the
  Omnipool. `lark-routes-setup` stores routes composed from the stored HOLLAR
  legs and pool 143 (referendum 442); without them harvest swaps cannot route.
- `//Alice` holds no HOLLAR. Public test inventory is minted from a
  governance-owned "Lark test inventory" facilitator bucket instead.
- Deferred deployment buys PRIME at up to 6 bps, which leaves the source and
  each Main cohort marginally below principal until carry covers it. Deposits
  and ramping stay blocked meanwhile. `lark-fund-main` records explicit test
  recapitalization: 1 HOLLAR per Main cohort and 0.5 HOLLAR to the source.

The first referendum (422) was read as approved on a short-lived early fork.
Its enactment was verified on the canonical chain at block 14 and marked in
the journal; later referenda ran unattended.

## Verified behavior

- **184/184 readiness checks passed** after deployment of the bootstrap seed.
- The UI deployment check passed in strict mode, and all 45 UI ABI functions
  match the deployed artifacts.
- The mirror publishes mainnet ETH, tBTC and PRIME prices; all ten market
  routes quote. PRIME↔HOLLAR costs 3–4 bps, inside the approved 6 bps.
- Keepers deployed both vaults' pending collateral, serviced Main interest and
  ramped the source towards its 1.05 health-factor target.
- A hosted keeper mined a harvest at block 568
  (`0x609fe292e0564862ab3933522fa3f03f7605399040b24566da2752abdecac208`):
  1.447 PRIME realized and compounded into both vaults' reward funds. The test
  depositor then claimed the full ETH reward (`claimYield`, 305,037,059,110,929
  shares).

## Execution policy

A 0 bps floor never clears real ETH/tBTC routes: test-size costs measured
14–66 bps against the MM oracle. Referendum 445 sets **100 bps on Lark only**
for both harvest lanes, all four Main interest-sale lanes and both vaults'
compound floor. PRIME↔HOLLAR entry and unwind stay at the approved 6 bps.
Mainnet still needs its own measured policy for every lane.

## Mainnet-synced market

Four bot services keep Lark close to mainnet, so the UI and keepers see
realistic prices and flow (see the [bot README](../lark-bots/README.md)):

- **Oracles:** `mirror` copies every MM oracle. Referendum 446 points the DIA
  updater slot and the pusher feeds at the mirror signer. All 15 feeds match
  mainnet.
- **Pool prices:** `pools` holds each Omnipool asset within 40 bps of mainnet's
  live Omnipool price, measured against HOLLAR. In steady state it makes
  roughly 3–11 corrections per 30 minutes.
- **Trade flow:** `replay` re-executes finalized mainnet extrinsic trades at
  full size, rebuilding each route from its per-hop events. In-batch failures
  fell from 24% to under 10% once routes were rebuilt and block-hook trades
  were left to the fork.
- **PRIME:** `markets` pegs only pool 143 (PRIME/HOLLAR) to the MM oracle,
  paying the 4 bps fee to hold the premium within 1 bp. A profit arb stopped
  at fee + edge and left loop entries above their 6 bps floor: replayed
  mainnet PRIME buys held the pool 5.7 bps rich and stalled every ramp. On
  mainnet nobody runs this peg, and pool 143 was 46% PRIME (~19 bps per buy).
  Mainnet's own pools sit off its oracles; on 7 October tBTC was 36–60 bps
  below and GETH about 2.7% below. Arbitraging ETH and tBTC to the oracle
  therefore fought pool sync and steadily drained the arb's HOLLAR.

Pool sync and replay inventory comes from referenda 447–450 and 452–453. All
of it is public test inventory, recorded in the journal, and is not yield.

Test mints above an asset's deposit limit (its `xcmRateLimit` per 43,200
blocks) are parked by the circuit breaker as reserved balance, and the asset is
locked. This hit tBTC and SKY, including the UI wallet's tBTC. Referendum 451
lifted both locks and released all five parked balances. Later mints are
checked against fuse headroom before submission.

## Remaining caveats

- Re-forking also reset every other Lark 4 user, including `gamma-keeper:lark4`
  and the retired September `propeller-looper` stack. Both now point at
  contracts that no longer exist.
- Test HOLLAR subsidies above are recorded and are not yield.
- Both keepers run on one Swarm host and no alert receiver is provisioned.
  Swarmpit's log endpoint intermittently returned nothing for the keepers, so
  liveness was confirmed from signer nonces and the readiness check instead.
- The next harvest waits for organic carry. The source's equity must clear
  principal plus its execution-cost reserve by 0.1% of principal.
- This deployment does not yet record a full leveraged exit (request, unwind,
  claim).
