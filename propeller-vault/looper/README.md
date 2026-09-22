# Propeller Looper

Permissionless maintenance of the shared `SubLoop` and its collateral vaults.

## Why it exists

The deploy/unwind legs dropped the pallet-DCA dependency — `pokeBorrow()` now
levers in a tranche **synchronously** (router sell, oracle-fair `minOut`) instead
of feeding a gradual DCA order. The gradualness that DCA used to provide now comes
from calling `pokeBorrow()` repeatedly off-chain. That's this bot.

`pokeBorrow()` is **permissionless** and fully bounded by the contract:

- borrows only down to `deployHfFloor` (= target HF) — can't over-lever,
- per-call amount capped at `deployTranche`,
- HOLLAR→aPRIME swap uses an Aave-oracle `minOut` to bound execution slippage.

So the signer needs **no role** — only enough HDX to pay gas. A caller can only
advance the ramp or waste their own gas on a no-op at floor.

The keeper also starts eligible withdrawals, repays debt, settles requests,
maintains synthetic collateral, and harvests. These operations require no keeper
role; harvest pays the configured harvester, not the caller.

## Loop

Each cycle (`POLL_INTERVAL_MS`, default 30s):

```
read source HF, repayment targets, route pause and emergency freeze
read each vault's pause, queue cursors and Main repayment target
  waiting request eligible by chain timestamp -> startUnwinds(16)
  source safety target or active unwind       -> pokeRepay()
  active vault settlement or Main repayment   -> pokeSettle()
  healthy, no pending work, no freeze         -> pokeBorrow()
periodically harvest(), maintainPeg(), pokeSettle(), then rebalance when allowed
```

The keeper checks each operating buffer's `ready()` state. A missing, unreadable
or below-target buffer blocks new source ramping and emits an alert; it does not
disable safety repayments. Settlement also runs for late source claims after
the collateral queue finishes, and the slow cycle services idle Main interest.
No keeper operation spends unallocated bootstrap or obtains treasury funding.
Monitor bootstrap separately: owned cash may be healthy while new deposits lack
sponsorship. See [buffer ownership and recovery](../docs/operating-buffer.md).

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

See `docker-stack.yml` for the full env list. Keep `replicas: 1` — two loopers
would collide on the signer's tx nonce.
