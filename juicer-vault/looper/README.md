# Juicer Looper

Permissionless maintenance of the shared `SubLoop` and its collateral vaults.

## Why it exists

The deploy/unwind legs dropped the pallet-DCA dependency — `pokeBorrow()` now
levers in a tranche **synchronously** (router sell, oracle-fair `minOut`) instead
of feeding a gradual DCA order. The gradualness that DCA used to provide now comes
from calling `pokeBorrow()` repeatedly off-chain. That's this bot.

`pokeBorrow()` is **permissionless**, subject to the following controls:

- borrows only down to `deployHfFloor` (= target HF) — can't over-lever,
- per-call amount capped when `deployTranche` is nonzero; activation requires an approved nonzero limit,
- HOLLAR→aPRIME swap uses an Aave-oracle `minOut` to bound execution slippage.

Maintenance needs **no role**, only target-chain transaction funding (WETH for
Hydration's EVM gas); `DEPOSIT_GUARDIAN_ROLE` additionally lets the keeper set a
vault's `deficitStop`, and the loop's `KEEPER_ROLE` lets it pass a router-quoted
floor with each intent (see below). A successful
call changes leverage and incurs execution costs. The shared [execution controller](../docs/execution-controls-implementation.md) additionally
bounds deployment of deposits, upward rebalances, harvests and source unwinds. Deposits
themselves supply collateral without borrowing or swapping. Controlled trades
use recent block-bound quotes while retaining their oracle floors.

The keeper also starts eligible withdrawals, repays debt, settles requests,
maintains synthetic collateral, and harvests. These operations require no keeper
role; harvest pays the configured harvester, not the caller.

Each submission is simulated. Zero-work results are skipped before estimation,
so successful no-ops do not become paid transactions. Productive calls are
estimated using the current RPC fee quote.
Gas and gas price receive a 20% margin. `MAX_TX_GAS` (default 16,777,216),
the live block gas limit, and the native EIP-7825 transaction cap (16,777,216)
all bound the submission; exceeding a budget alerts and skips the transaction.
Failed estimation never falls back to a fixed gas allowance. A second simulation
at the exact submission allowance rejects invalid estimates. The raw
`eth_estimateGas` request includes a gas ceiling with room for the 20% margin;
the client library's contract-estimation helper omits this field. Reverted receipts
are reported and do not trigger follow-up work that assumes success.
Operators must calibrate queue and route sizes on the deployed runtime: a
budget rejection does not automatically split work or make an oversized call
executable. Native 32-request settlement requires more than 12M gas before
refunds, so lowering the operator budget can prevent queue progress. Starts
use eight requests to retain extra headroom. The native deployment harness uses a separate 10% creation margin,
and records the exact artifact, receipt and remaining transaction headroom.

## Loop

Each cycle (`POLL_INTERVAL_MS`, default 30s):

```
read source HF (effectiveHealthFactor), repayment targets, route pause and emergency freeze
  low HF                                  -> schedule safety repayment first
read each vault's pause, queue cursors and Main repayment target
  waiting request eligible by chain timestamp -> startUnwinds(8)
  source or vault deficit above DEFICIT_STOP_BPS -> no pokeBorrow; setDeficitStop(true), any operator
  below DEFICIT_RESUME_BPS, flag set, duty slot   -> setDeficitStop(false)
  source safety target                        -> pokeRepay() on the router
  active unwind                               -> pokeRepay(), or pokeRepayQuoted() with intents
  active vault settlement, Main repayment target
    or unallocated source proceeds            -> pokeSettle()
  healthy, worthwhile harvest, duty slot      -> quoted bounded harvest()
  pending collateral, eligible vault, duty slot -> quoted bounded rebalance(), also while exits wait
  healthy, no pending work, duty slot         -> quoted bounded pokeBorrow(), or with intents
    (also for idle deposit cash) pokeBorrowQuoted(router dry-run rate)
  intent in flight                            -> nothing new is submitted
    fill or refund landed, duty slot          -> reconcile()
    unfilled ICE_STALL_BLOCKS, or input still away
    ICE_CLEANUP_BLOCKS past the deadline      -> alert; cleanup_intent with a dev signer
    emergency pause, any operator             -> removeIntent(pallet intent id)
  synthetic buffer below 25bp                 -> top up to 50bp
  no pending deployment, periodic duty slot    -> quoted rebalance when allowed
then, for each vault:
  settled request below the queue head      -> claim(id, owner)
  exit surplus >= CLAIM_MIN_SURPLUS         -> claimSurplus(id)
  PRIME or collateral oracle update since its last sync,
    or SYNC_EVERY elapsed, duty slot        -> sync()
independent read loop, including during slow writes/receipt waits:
  effective source HF, synthetic coverage, Main interest, stale RPC, stuck receipts
```

Health-factor decisions (the de-lever trigger, the ramp floor and the HF alert)
use `effectiveHealthFactor()`: Aave's own HF dips while an entry's HOLLAR is in
flight as an intent, and the effective one nets that HOLLAR against the debt.

No on-chain readiness flag gates the keeper: Main debt ledgers no longer expose
`ready()`. An unreadable vault queue still blocks new source ramping without
disabling safety repayments. Settlement also runs for
late source claims after collateral settlement. Every cycle can realize eligible yield before optional source ramping and then
reinvest the resulting collateral. `pokeSettle` is only sent for redeem-queue
work. Main interest is paid from harvest servicing and at exits; the keeper never
settles an idle vault just to service interest, never obtains treasury money and
never widens slippage. See [yield funding and recovery](../docs/main-debt-servicing.md).

Delivery means a user signs only `requestRedeem`: settled collateral and exit
surplus are pushed to the request owner. The scan resumes at the first request
still owed something, looking back `CLAIM_LOOKBACK` requests after a restart.

The default cooldown is 12 hours BEFORE unwinding starts. It is configured per
vault by governance through `setWithdrawalDelay(uint32 seconds)`. Existing
requests retain their recorded `unwindEligibleAt`; zero disables the delay for
new requests. A later shorter delay does not jump an older FIFO request.
Waiting shares remain invested and earn their share of yield; collateral and
debt are snapshotted by `startUnwinds`, not `requestRedeem`.

`SubLoop.pauseEmergency()` is the guardian's source-wide incident freeze. It
blocks deposits, exits, harvests and new risk across all attached vaults while
retaining safety deleveraging and Main peg maintenance. Plain share transfers
continue: they check only the vault's own pause. Only governance's
`ADMIN_ROLE` can call `unpauseEmergency()`. A vault's local `pause()` blocks its
own user flows, transfers included, and reverts while the source emergency is
set, so pause vaults first when balances must stop moving; local `unpause()`
also requires `ADMIN_ROLE`.

`SubLoop.pause()` is a separate swap-route kill switch: it stops `pokeRepay`
as well as new borrowing. Use it when route execution itself is unsafe, not as
a substitute for `pauseEmergency()`. Neither a stopped keeper nor this route
pause alone prevents users from calling a vault's existing claim function.

Monitor `queueTail - queueUnwind` and `pendingWithdrawalShares` for waiting
requests, `queueUnwind - queueHead` for active unwinds, and the scheduled/start
events. Request counts alone are susceptible to tiny-request spam; monitor
requested collateral value and its fraction of vault assets too. The keeper
does not automatically decide when to freeze or reopen; the deficit stop is the
only exception.

Monitor each vault's `roundingReserve()` and `RoundingReserveUsed` events too.
Both proposal generation/readiness and the keeper use the same required
`JUICER_ROUNDING_RESERVES` policy. Supply exactly one entry per vault, with
`vault`, native `assetId`, and integer-string `minimum` / `target` amounts in
collateral base units. The target must exceed the alert minimum, and the minimum
must exceed the chain's existential deposit. There is no automatic budget default.
The proposal requires the Aave-manager account to be prefunded with the donation;
it adds custody dust protection, approves only the needed top-up, funds the vault,
then clears the allowance. It never withdraws treasury assets automatically.
Readiness checks the runtime account mapping, dust protection, native asset ID,
minimum balance and raw collateral backing. The keeper emits `[ALERT]` log lines
below the approved minimum or on a failed/unbacked read; connect these to the
operations alert pipeline. Monitoring failures do not stop safety debt service.
For native-token collateral, keep a margin above the asset's existential
deposit and verify custody-account dust protection; a positive buffer alone
does not establish those conditions.
Governance funds this separate collateral dust budget through
`fundRoundingReserve(uint256 assets)` before opening deposits. Anyone may donate
more, including while frozen; funding mints no shares. An exhausted buffer can
block deposits, unwind starts, or settlement rather than charge rounding losses
to users. Replenishment allows retry without reducing pending claims. The keeper
does not spend treasury funds or automatically replenish this buffer.

Policy shape (replace addresses and amounts with reviewed deployment values;
these illustrative amounts are not an approved operating budget):

```sh
export JUICER_ROUNDING_RESERVES='[{"vault":"0x1111111111111111111111111111111111111111","assetId":34,"minimum":"10746910263300","target":"21494820526600"}]'
```

Include a separate entry for every address in `VAULT_ADDRESSES`. Proposal and
readiness scripts use the same JSON against their `JUICER_VAULTS` list.
The Docker stack requires and forwards this variable as well.

### Deficit stop

Underfunding is checked by the keeper, not by the contracts. Each cycle it reads
two deficits, both in bps:

- source: `negativeCarryBps()`, principal equity against live equity;
- vault: with backing = `equityOf(vault) − sourceValue()`, the larger of the
  active Main debt (`activePosition`) not covered by backing plus
  `activeFunds()`, and `requiredSourceBacking()` (which grosses up the protocol
  fee on unpaid interest) minus backing, in bps of the debt, rounded up. While
  source proceeds are unallocated (`pendingSourceAccounting`) `activeFunds` is
  stale, so that view is skipped until `pokeSettle` has run.

A vault's level is the larger of the two. Each vault has a `deficitStop` flag
that only `DEPOSIT_GUARDIAN_ROLE`, held by the keepers, can set; deposits revert
while it or governance's `depositsPaused` is set. The flag is the hysteresis
state: above `DEFICIT_STOP_BPS` any operator sets it and the ramp stops, below
`DEFICIT_RESUME_BPS` the operator on duty clears it once the vault is not frozen
and the ramp resumes, and in between it stays as it is. No transaction is sent
when the flag already has the wanted value. Because the state is on-chain, a
restarted keeper and the second operator act on the same flag. The keeper never
reads or changes `depositsPaused`; other deposit pauses stay with governance
(`GUARDIAN_ROLE`). An unreadable deficit holds the ramp and leaves the flag as it
is. Every set and clear is an `[ALERT]` line; a failed attempt alerts once and is
retried every cycle.

### Sync cadence

Transfers do not allocate yield, so after a price update `sync()` is what moves
it to holders. The keeper calls each vault's permissionless `sync()` after a price
that changes the allocation moves: PRIME for every vault, and the vault's own
collateral. It polls each asset's Aave oracle source (`getSourceOfAsset`, then
`latestRoundData`); a newer `updatedAt`, or an answer that moved under an
unchanged `updatedAt`, is an update. Without updates a vault is synced every
`SYNC_EVERY` seconds. A vault's last sync is the newest of the keeper's own syncs
and the `Allocated()` events of its yield accounting, which every allocation
emits: deposit, `requestRedeem`, `startUnwinds`, `rebalance` and `sync`, including
the Harvester's. Only the operator on duty syncs; the other finds that event on
its own slot and skips. Frozen vaults, and vaults with unallocated source
proceeds, are not synced. Unreadable oracles leave only the timer. The harvestable
shares `sync()` returns are ignored.

### ICE intents

With `intentTtl() != 0` the loop's entries and routine unwind slices go out as
ICE intents, one in flight at a time. The keeper calls `pokeBorrowQuoted` and
`pokeRepayQuoted` directly, not through the controller's `execute`, only on its
duty slot and only while nothing is in flight. Safety repayments stay on the
controller's router path.

The quote comes from two dry runs. A substrate `DryRunApi` run of the keeper's own
call (`evm.call`) shows the `IntentSubmitted` it would emit, which gives the
intent's real size. A dry-run `router.sell` of that size over the loop's own route
gives the output; keeperQuote is output units per 1e18 input units. Exits are dry-run
from the loop's account, which holds the aPRIME. An entry borrows inside its own call,
so unless the loop already holds the HOLLAR, `ICE_QUOTE_HOLDER` (the Omnipool account
by default) stands in. The contract floors the quote with the oracle cap and its
drift allowance. Without a router quote an entry waits and an exit goes out at the
oracle floor (quote 0). Without `KEEPER_ROLE` the keeper sends the permissionless
`pokeBorrow()`/`pokeRepay()` directly and alerts once. Deposits wait in the loop as
cash, so idle HOLLAR triggers an entry even without ramp headroom.

While an intent is in flight the keeper simulates `reconcile()` every cycle, and the
operator on duty sends it once a fill or refund has landed without its callback.
It alerts once when an intent stays unfilled for `ICE_STALL_BLOCKS` blocks (solver
quiet, or the limit out of reach) and once when an expired intent's input is still
away `ICE_CLEANUP_BLOCKS` blocks after its deadline; both count from the block the
keeper first saw the condition. Expiry refunds come from the intent pallet's
offchain worker. With `ICE_CLEANUP_SURI`, a dev derivation such as
`//Alice//cleanup` (anything not starting with `//` is refused, so no real secret
fits), the operator on duty calls `cleanup_intent` itself. Under `pauseEmergency()`
any operator calls `removeIntent` with the pallet intent id, read from
`intent.accountIntents`. The substrate side is reached at `SUBSTRATE_RPC_URL`,
by default the first RPC URL; Hydration nodes serve both interfaces there.

## Run

Local:

```sh
npm install
SUBLOOP_ADDRESS=0x… VAULT_ADDRESSES=0x… LOOPER_PRIVATE_KEY=0x… \
  RPC_URL=https://hdx.tarn.hydration.cloud npm start
```

Swarm:

```sh
docker stack deploy -c docker-stack.yml juicer-looper
```

See `docker-stack.yml` for the full environment. Keep one process per signer.
Deploy a second stack/operator with a different key and RPC infrastructure.
Both set `OPERATOR_COUNT=2`; assign indexes `0` and `1`. Optional work rotates
in 60-second slots. Both monitor and perform urgent source repayment continuously;
a failed operator does not block the other's slot. Do not share signer keys.

Set `EXECUTION_CONTROLLER` to the common controller. Swap previews verify the
source and participating contracts are bound to that controller. Set
`GAS_ASSET_ADDRESS` to an approved oracle-listed token when operator-funded gas
is disabled. `RPC_URLS` is a
comma-separated fallback list, defaulting to `RPC_URL`. The Docker
stack requires the controller and operator index explicitly.

Default scheduling values (operator examples, not approved production policies):

| Variable | Default | Meaning |
| --- | ---: | --- |
| `HARVEST_MIN_USD8` | `100000000` | $1 minimum gross harvest for ordinary batching |
| `SPONSORED_GAS` | `true` | Operators pay gas; exclude it from user harvest profitability |
| `HARVEST_MAX_GAS_BPS` | `10` | When sponsored gas is false, gas budget up to 0.1% of gross converted yield |
| `HARVEST_MAX_DELAY_SECONDS` | `86400` | Bypass economic delay after a day, when a safe harvest exists |
| `MAIN_INTEREST_URGENT_USD8` | `1000000000` | Urgent Main interest threshold; HOLLAR valued at par |
| `QUOTE_TTL_SECONDS` | `60` | Quote deadline, must fit the controller deployment |
| `QUOTE_DRIFT_BPS` | `2` | Additional tolerance from observed output; cannot widen oracle floors |
| `QUOTE_SIZE_STEPS` | `6` | Bounded size samples, including when a large slice already succeeds |
| `QUOTE_INCLUSION_BLOCKS` | `2` | Blocks of controller quote age kept for inclusion; older quotes are re-pinned before signing |
| `QUOTE_DEPTH_BLOCKS` | `3` | Quote this many blocks below the head, so a reorg of the newest blocks can't void the bound hash; with `QUOTE_INCLUSION_BLOCKS` it must fit the controller's `maxQuoteBlocks` (alerted otherwise) |
| `RECEIPT_TIMEOUT_MS` | `60000` | Re-send interval for the same signed transaction while no receipt appears |
| `SLICE_PRICE_TOLERANCE_BPS` | `1` | Choose the largest slice close to the best sampled unit prices; cannot widen oracle floors |
| `SAFETY_INTERVAL_MS` | `30000` | Independent read-loop interval |
| `RPC_STALE_SECONDS` | `120` | Alert threshold for an old chain head |
| `OPERATOR_SLOT_SECONDS` | `60` | Optional-work duty-slot duration |
| `DEFICIT_STOP_BPS` | `50` | Above this source or vault deficit, stop the ramp and set the vault's `deficitStop` |
| `DEFICIT_RESUME_BPS` | `25` | Below this, resume the ramp and clear `deficitStop`; must be below the stop, `0` never clears |
| `SYNC_EVERY` | `3600` | Seconds between vault syncs when no PRIME or collateral oracle update calls for one sooner |
| `ICE_STALL_BLOCKS` | `10` | Blocks an intent may stay unfilled before the solver is reported quiet |
| `ICE_CLEANUP_BLOCKS` | `10` | Blocks past an intent's deadline before its missing refund is cleaned up (with a signer) or alerted |
| `ICE_QUOTE_HOLDER` | Omnipool account | 32-byte account whose HOLLAR stands in for an entry's router dry run |
| `ICE_CLEANUP_SURI` | unset | Dev-derived (`//…`) signer for `cleanup_intent`; unset means expired intents only alert |
| `SUBSTRATE_RPC_URL` | first of `RPC_URLS` | Substrate RPC for dry runs, pallet intent ids and cleanup |

A submitted transaction keeps its signer locked until its receipt is known.
The nonce is locked before broadcast, so a send error that still reached a node
cannot reuse it. Without a receipt, the keeper re-sends the identical signed
bytes every `RECEIPT_TIMEOUT_MS`; it never signs another payload for that nonce.
The lock clears once the nonce is mined. Read monitoring continues while a
receipt is pending and alerts after two minutes; a confirmed receipt from the
monitor also releases the lock. Connect `[ALERT]` logs to the operators' monitoring
pipeline and rehearse handover before launch. No alerts are sent externally by
default. See the [configuration and activation checklist](../docs/execution-controls-implementation.md#activation-configuration).
