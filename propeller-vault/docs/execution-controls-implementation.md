# Deposit, harvest and keeper execution controls

Review implementation for PR #62. This does not activate production policies.
The October 4 revision separates collateral deposits from debt deployment and
adds price-aware slice selection, pacing and quoted source unwinds. Earlier
APY models and native reports describe their recorded revisions; they do not
establish an APY or execution throughput for this revision.
The latest [swap-cost analysis with operator-funded gas](sponsored-gas-swap-costs-2026-10-03.md)
uses funded user crypto as the objective and records the $10/month shared
infrastructure budget separately. It supersedes the gas-saving interpretation
of the earlier model; it does not change live keeper policy.
The [three-round operations model](operations-tuning-three-rounds-2026-10-03.md)
includes this controller's gas and throughput limits, productive keeper writes,
and explicit shared operating-cost sensitivities. Its returns remain conditional
on market rates and external liquidity replenishment. Validation and measured native gas are recorded
in the [3 October verification report](execution-controls-validation-2026-10-03.md).

## Trade controls

`ExecutionController` holds continuously replenishing token-volume budgets.
A group specifies an input token, burst capacity, refill per second and expiry.
Each `(consumer, input, output)` lane specifies a positive minimum and maximum
trade, an explicit MM-oracle shortfall bound and a safety flag. Each group also
has a minimum interval between transactions; another transaction in the same
block cannot consume that group. Several legs in one atomic harvest may share
its remaining credit. Available input is the smaller of lane maximum and group credit; amounts
below the minimum are unavailable. All quantities use the input token's native
decimals. Reconfiguring a group preserves consumed credit, and changing its token
is prohibited. A refill rate is a permitted ceiling, not proof that pool inventory
has arrived.

- Deposits supply collateral and mint funded vault shares without borrowing or
  swapping. `reinvestAssets` tracks pooled collateral awaiting deployment,
  including deposits and compounded yield. It is borrowing credit, not a
  per-user queue or an exact deployment-progress percentage. Waiting collateral
  incurs no new HOLLAR debt and retains its withdrawal claim.
- All HOLLAR→aPRIME buys consume one source lane: Main deployment, upward
  rebalances and source ramps cannot acquire separate budgets by changing users,
  vaults or keepers. Each borrow is capped before creation by both source tranche
  and admission capacity, and is swapped in the same atomic transaction.
- Upward Main rebalances take the available bounded amount. Unused reinvestment
  credit remains for a subsequent pass, including a slice below the entry lane
  minimum. Existing backing/readiness checks still apply; tranche limits do not
  permit borrowing through an existing shortfall, and new debt requires an
  intact synthetic floor. Waiting or unsettled exits pause price-driven resizing
  only: deposited and earned credit keeps deploying, as immediate deposits did
  before deferral. Settled but unclaimed requests block nothing.
- PRIME→collateral lanes share one PRIME group and have their own trade caps.
  The Harvester bounds withdrawals before burning source shares, then compounds
  only that owner's slice. Remaining earned yield stays invested and owned.
  Small tails wait for additional yield. Parked donations use the same limits
  and wait behind owned carry rather than triggering a second dust trade.
- Each Main-interest collateral→HOLLAR swap has its own lane, minimum, maximum
  and budget. The complete harvest preview includes this second trade. A need
  below the lane minimum sells the minimum when the fresh collateral covers it;
  the surplus HOLLAR stays as active Main cash for later interest. A vault whose
  due interest sale cannot trade now (expired, paced or exhausted lane, or no
  quote) sits the harvest out, parked donations included, while other vaults
  proceed. A sale above the lane's available size still rolls back the batch,
  and the keeper retries smaller batches.
- Source aPRIME→HOLLAR unwinds have a separate quoted lane. An explicitly enabled
  safety lane may bypass expiry, volume credit and pacing while a safety repayment
  is outstanding; it still requires a fresh quote, bounded size and the same
  oracle price floor. A safety repayment on an unflagged lane uses its normal
  budget. Expiry stops new entry and harvest trades, not exits: the flagged
  unwind lane keeps its credit, pacing and price bounds after its policy lapses.
  A routine exit whose remaining need is below the lane minimum sells the minimum,
  capped by the source's aPRIME, so it can complete; the excess stays as source
  cash. Direct `pokeRepay` can repay existing cash but cannot swap
  without a controller execution context. Cash settlement needs no swap quote.

`configurePrice(lane, maxShortfallBps, safety)` bounds the **total** output
shortfall against the live MM oracle, including route fees and slippage. Zero
means oracle price or better and is the fail-closed default. A configured 10bp
bound, for example, requires at least 99.9% of oracle output. Quote-to-inclusion
tolerance cannot widen it. No production tolerance has been approved here.
Pacing allows time for arbitrage to refill liquidity; fresh executable prices,
not the passage of time, decide whether another slice can execute.

Bind the same controller to the source, Harvester and every vault. Binding is
one-time and nonzero; unconfigured test stacks omit controller restrictions but
still use deferred deposits and the source tranche cap.
Production readiness now requires the bindings, every required route/action,
shared PRIME budget and explicitly approved policy values. There are no default
production trade sizes or replenishment rates.

This revision is a fresh-deployment candidate. The controller's consumer ABI
now includes the oracle-valued output, and Main debt/compound helpers are
immutable deployment components. Do not upgrade an earlier controlled stack
piecemeal: its one-time controller binding cannot be replaced through the normal
setter. Existing deployment migration needs its own reviewed plan. The older
`native-execution-controls.mjs` rehearsal describes the pre-deferred revision;
use fresh `native-deploy.mjs`, `native-discount.mjs` and
`native-deferred-deposit.mjs` for this revision's native deposit checks.

## Quotes and callers

`preview(target, calldata)` executes the actual registered action in a subcall
that **always reverts**, then returns its result and observed fills. Even submitting
preview as a real transaction must leave balances, debt, ownership and budgets
unchanged. Every preview enforces both the configured MM floor and each
consumer's existing independent Aave-oracle floor.

Clients call preview using `eth_call` at a known recent block. They submit
`execute(target, calldata, quotedBlock, quotedHash, deadline, quotes)` with:

1. The quoted block's canonical hash, within the deployment's block-age limit.
2. A short expiry; execution rejects elapsed deadlines or deadlines beyond the
   deployment's maximum remaining lifetime.
3. A maximum input and positive output floor per lane. A smaller admitted trade
   receives a proportionally rounded-up floor. The existing oracle floor always
   wins if it is stricter.

These are permissionless caller price bounds, not authenticated market prices or
a new trusted oracle. The block hash prevents using an expired/forked reference;
no contract can prove a caller actually requested an RPC quote. Oracle provenance
and freshness remain separate activation requirements. A changed market can
still reject a quote at inclusion; retry from a fresh preview without widening
oracle tolerance.

`previewBounded` accepts optional input ceilings for selected lanes. The keeper
samples up to `QUOTE_SIZE_STEPS` (default six) smaller sizes after the full preview, even
when the full slice succeeds, leaving Main-servicing capacity unchanged. It
selects the largest primary input within `SLICE_PRICE_TOLERANCE_BPS` (default
one) of the best sampled unit prices, checking servicing legs too. The last
sample reaches the configured minimum even for a large initial capacity. It does not
drop an active harvest recipient to make a quote look cheaper. This is bounded
sampling, not proof of a global optimum. Urgent safety repayment takes the first
acceptable quote. Only EVM reverts trigger retry with a smaller size; RPC failures
abort. Failed previews spend no gas on-chain and cannot consume budget.

The controller only forwards governance-registered selectors. Depositors approve
the **vault**, not the controller. The deposit helper pulls from the controller's
active original caller and mints to the requested receiver. No signatures,
quote-publisher role, parked customer assets or standing controller allowances
are needed. Direct legacy buys/compounds fail once their control is bound; safety
repayment and cash settlement remain directly callable.

The UI approves and deposits directly into the vault. It must verify
`deferredDeployment() == true` before enabling deposits, so an older deployment
cannot silently retain immediate swapping. Deposit amounts use balance and TVL
limits, not trade-size limits. Keeper swap actions use the execution envelope.
Return values added to maintenance functions report
useful work; selectors are unchanged, and clients that ignore transaction return
data continue to work.

## Keeper economics and redundancy

The keeper previews each write and skips successful zero-work results. The
synthetic peg tops up to a 50bp buffer when less than 25bp remains, avoiding a paid
top-up for every tiny interest increment. Clearing a completed source safety
commitment counts as work so optional ramping cannot remain stuck behind it.

Gas is operator-funded by default (`SPONSORED_GAS=true`), so it is excluded from
the user's harvest profitability gate. The $1 ordinary batching minimum still
applies. When explicitly disabled, the keeper compares estimated gas with gross
oracle-valued yield, defaulting to a 10bp gas budget. A 24-hour maximum batching
wait after the previous successful harvest, or $10-equivalent outstanding Main
interest, bypasses the economic delay when a safe harvest is available. The
interest threshold values HOLLAR at par, matching the strategy's existing debt
convention. These operator settings cannot bypass on-chain minimums, budgets,
expiry, source harvestability or swap floors. They do not promise a harvest when
the strategy lacks safely realizable yield.

Every controlled swap uses the controller's pinned preview and quotes with
2bp quote-to-inclusion tolerance by default. This is additional protection; it
never widens the independently configured oracle tolerance. Estimates and fee
quotes retain their 20% margins and the native transaction gas ceiling.

Servicing quotes allow up to twice the observed input to accommodate interest
accruing before inclusion, with the output floor scaled by the same factor.
This preserves the quoted unit price and remains inside the configured trade
and volume limits. Primary buy/harvest inputs keep their measured caps. A newly
required, previously absent service leg still requires a refreshed preview.

Source safety runs before optional trades. Pending collateral deployment is
attempted every eligible cycle before extra source leverage; vault order rotates
to avoid a fixed winner for shared admission credit. Peg checks run each cycle. A separate
source ramp waits until the next cycle after a successful Main rebalance so it
uses refreshed backing, repayment and health-factor state. An independent
30-second read loop monitors source HF, Main backing, interest, synthetic coverage,
stale RPC heads and stuck receipts even while a transaction is awaiting inclusion.
The nonce is locked before broadcast. Without a receipt, the keeper re-sends the
identical signed bytes and releases the lock once that nonce is mined; it never
signs another payload for the nonce. A quote that would age out of the
controller's block window before inclusion is re-pinned at the chosen sizes
just before signing.

Run independent operators with separate signers, balances and RPC infrastructure.
`OPERATOR_COUNT`, unique `OPERATOR_INDEX` values and 60-second duty slots rotate
optional work; every operator continues safety monitoring and urgent source
repayment. A stopped primary does not need to release a lock or heartbeat before
the next operator's slot. Keep one process per signer. On-chain budgets remain
the final limit if operators race. A race can still cost a reverted transaction;
this is not an exclusive on-chain keeper lease.

The batching deadline is measured since the last successful global harvest; it
is not a per-vault realization deadline. Vaults consume shared credit in registered
order. A saturated budget needs a multi-vault backlog rehearsal and per-vault
age monitoring to show that each collateral route progresses. A shared rate cap
alone does not provide fair scheduling under sustained saturation.

## Activation configuration

Before unpausing public deposits:

1. Deploy the controller with approved quote-age limits. Configure nonzero finite
   lane sizes, shared directional budgets, pacing, refill rates, policy expiry,
   total MM shortfall bounds and an explicit source-unwind safety policy.
2. Register `rebalance()` on each vault, `pokeBorrow()` and `pokeRepay()` on the
   source, and `harvest(uint256[])` on the Harvester. Bind
   the same controller to all of them.
3. Set `EXECUTION_CONTROLLER` in each keeper. Every swap preview checks the
   relevant source/vault/Harvester bindings against it. Set an oracle-listed
   `GAS_ASSET_ADDRESS` if `SPONSORED_GAS=false`. Set `RPC_URLS` to the operator's comma-separated RPC endpoints; use
   independent infrastructure across operators. Approve batching/urgency settings.
4. Supply `PROPELLER_EXECUTION_CONTROLLER` and `PROPELLER_EXECUTION_POLICY` to
   `verify-readiness.ts`. The latter JSON has `maxQuoteAge`, `maxQuoteBlocks`,
   `budgets: [{group, capacity, refillPerSecond, expiresAt, minIntervalSeconds}]`
   and `limits: [{lane, group, minimum, maximum, maxShortfallBps, safety}]`.
   Amounts/timestamps use integer strings; `maxShortfallBps` is an integer and
   `safety` is a boolean. Only the source unwind lane may enable safety.
   Obtain lane IDs from `controller.lane(consumer,input,output)` and compare the
   actual wiring against the approved governance payload.
5. Complete a direct UI deposit followed by several quoted deployment slices,
   a withdrawal before deployment, partial harvest with Main servicing,
   expired-policy rejection of entry/harvest while exits continue, keeper
   handover and safety/exit rehearsal on the
   exact deployment. Public activation still needs approved liquidity/refill
   limits, recovery funding and independent review.

The controller does not implement deposit/exit matching, a per-depositor admission
queue, automatic treasury funding, a provider replenishment service or a revised
source-loss policy. Those must not be assumed in return estimates.

The [four-round historical model](historical-apy-four-rounds-2026-10-03.md)
tests these controls against 90 days of pool, oracle and interest-index inputs.
It finds no supported parameter improvement on its held-out period. Adaptive
harvest sizing helps the ideal-liquidity BTC diagnostic, but observed entry
quotes remain the dominant constraint. It changes no activation settings.
