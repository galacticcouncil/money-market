# Propeller Looper

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

The signer needs **no role**, only target-chain transaction funding (WETH for
Hydration's EVM gas). A successful
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
read source HF, repayment targets, route pause and emergency freeze
  low HF                                  -> schedule safety repayment first
read each vault's pause, queue cursors and Main repayment target
  waiting request eligible by chain timestamp -> startUnwinds(8)
  source safety target or active unwind       -> pokeRepay()
  active vault settlement or Main repayment   -> pokeSettle()
  healthy, worthwhile harvest, duty slot      -> quoted bounded harvest()
  pending collateral, eligible vault, duty slot -> quoted bounded rebalance(), also while exits wait
  healthy, no pending work, duty slot         -> quoted bounded pokeBorrow()
  synthetic buffer below 25bp                 -> top up to 50bp
  no pending deployment, periodic duty slot    -> quoted rebalance when allowed
after a successful harvest, or periodically otherwise:
  pokeSettle()
independent read loop, including during slow writes/receipt waits:
  source HF, synthetic coverage, Main backing/interest, stale RPC, stuck receipts
```

The keeper checks each Main debt ledger's `ready()` state. Missing/unreadable
accounting, insufficient backing or incomplete source allocation blocks new
source ramping without disabling safety repayments. Settlement also runs for
late source claims after collateral settlement. Every cycle can realize eligible yield before optional source ramping and then
reinvest the resulting collateral. The periodic fallback also services Main
interest from available proceeds; the keeper never obtains treasury money or widens
slippage. See [yield funding and recovery](../docs/main-debt-servicing.md).

The default cooldown is 12 hours BEFORE unwinding starts. It is configured per
vault by governance through `setWithdrawalDelay(uint32 seconds)`. Existing
requests retain their recorded `unwindEligibleAt`; zero disables the delay for
new requests. A later shorter delay does not jump an older FIFO request.
Waiting shares remain invested and earn their share of yield; collateral and
debt are snapshotted by `startUnwinds`, not `requestRedeem`.

`SubLoop.pauseEmergency()` is the guardian's source-wide incident freeze. It
blocks exits, share transfers, and new risk across all attached vaults while
retaining safety deleveraging and Main peg maintenance. Only governance's
`ADMIN_ROLE` can call `unpauseEmergency()`. A vault's local `pause()` blocks its
own user flows; local `unpause()` also requires `ADMIN_ROLE`.

`SubLoop.pause()` is a separate swap-route kill switch: it stops `pokeRepay`
as well as new borrowing. Use it when route execution itself is unsafe, not as
a substitute for `pauseEmergency()`. Neither a stopped keeper nor this route
pause alone prevents users from calling a vault's existing claim function.

Monitor `queueTail - queueUnwind` and `pendingWithdrawalShares` for waiting
requests, `queueUnwind - queueHead` for active unwinds, and the scheduled/start
events. Request counts alone are susceptible to tiny-request spam; monitor
requested collateral value and its fraction of vault assets too. The keeper
does not automatically decide when to freeze or reopen.

Monitor each vault's `roundingReserve()` and `RoundingReserveUsed` events too.
Both proposal generation/readiness and the keeper use the same required
`PROPELLER_ROUNDING_RESERVES` policy. Supply exactly one entry per vault, with
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
export PROPELLER_ROUNDING_RESERVES='[{"vault":"0x1111111111111111111111111111111111111111","assetId":34,"minimum":"10746910263300","target":"21494820526600"}]'
```

Include a separate entry for every address in `VAULT_ADDRESSES`. Proposal and
readiness scripts use the same JSON against their `PROPELLER_VAULTS` list.
The Docker stack requires and forwards this variable as well.

## Run

Local:

```sh
npm install
SUBLOOP_ADDRESS=0x… VAULT_ADDRESSES=0x… LOOPER_PRIVATE_KEY=0x… \
  RPC_URL=https://hdx.tarn.hydration.cloud npm start
```

Swarm:

```sh
docker stack deploy -c docker-stack.yml propeller-looper
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
| `RECEIPT_TIMEOUT_MS` | `60000` | Re-send interval for the same signed transaction while no receipt appears |
| `SLICE_PRICE_TOLERANCE_BPS` | `1` | Choose the largest slice close to the best sampled unit prices; cannot widen oracle floors |
| `SAFETY_INTERVAL_MS` | `30000` | Independent read-loop interval |
| `RPC_STALE_SECONDS` | `120` | Alert threshold for an old chain head |
| `OPERATOR_SLOT_SECONDS` | `60` | Optional-work duty-slot duration |

A submitted transaction keeps its signer locked until its receipt is known.
The nonce is locked before broadcast, so a send error that still reached a node
cannot reuse it. Without a receipt, the keeper re-sends the identical signed
bytes every `RECEIPT_TIMEOUT_MS`; it never signs another payload for that nonce.
The lock clears once the nonce is mined. Read monitoring continues while a
receipt is pending and alerts after two minutes; a confirmed receipt from the
monitor also releases the lock. Connect `[ALERT]` logs to the operators' monitoring
pipeline and rehearse handover before launch. No alerts are sent externally by
default. See the [configuration and activation checklist](../docs/execution-controls-implementation.md#activation-configuration).
