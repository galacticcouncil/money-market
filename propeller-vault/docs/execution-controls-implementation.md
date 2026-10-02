# Deposit, harvest and keeper execution controls

Review implementation for PR #62. This does not activate production policies.
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
trade. Available input is the smaller of lane maximum and group credit; amounts
below the minimum are unavailable. All quantities use the input token's native
decimals. Reconfiguring a group preserves consumed credit, and changing its token
is prohibited. A refill rate is a permitted ceiling, not proof that pool inventory
has arrived.

- All HOLLAR→aPRIME buys consume one source lane: initial deposits, Main upward
  rebalances and source ramps cannot acquire separate budgets by changing users,
  vaults or keepers. An oversized immediate deposit reverts atomically. There is
  no pending-deposit queue or borrowed HOLLAR waiting for admission.
- Upward Main rebalances take the available bounded amount. Unused reinvestment
  credit remains for a subsequent pass. Existing backing/readiness checks still
  apply; tranche limits do not permit borrowing through an existing shortfall.
- PRIME→collateral lanes share one PRIME group and have their own trade caps.
  The Harvester bounds withdrawals before burning source shares, then compounds
  only that owner's slice. Remaining earned yield stays invested and owned.
  Small tails wait for additional yield. Parked donations use the same limits
  and wait behind owned carry rather than triggering a second dust trade.
- Each Main-interest collateral→HOLLAR swap has its own lane, minimum, maximum
  and budget. The complete harvest preview includes this second trade. An
  unavailable service route rolls back the whole batch.
- Source safety repayment, ordinary unwind servicing and settlement of available
  cash do not consume admission/optional-harvest credit or require its quote
  context. Existing HF, tranche, pause and oracle swap guards remain applicable.

Bind the same controller to the source, Harvester and every vault. Binding is
one-time and nonzero; unconfigured historical/test stacks keep their old behavior.
Production readiness now requires the bindings, every required route/action,
shared PRIME budget and explicitly approved policy values. There are no default
production trade sizes or replenishment rates.

## Quotes and callers

`preview(target, calldata)` executes the actual registered action in a subcall
that **always reverts**, then returns its result and observed fills. Even submitting
preview as a real transaction must leave balances, debt, ownership and budgets
unchanged. It is not a zero-minimum route: each consumer still enforces its existing
independent Aave-oracle floor during preview.

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
uses at most four progressively smaller previews when a large buy/harvest
reverts, leaving the Main-servicing lane's capacity unchanged. This lets a smaller
harvest service interest when a full batch cannot fit that route. Only EVM
execution failures trigger resizing; RPC failures do not. Failed previews spend
no gas on-chain and cannot consume budget.

The controller only forwards governance-registered selectors. Depositors approve
the **vault**, not the controller. The deposit helper pulls from the controller's
active original caller and mints to the requested receiver. No signatures,
quote-publisher role, parked customer assets or standing controller allowances
are needed. Direct legacy buys/compounds fail once their control is bound; safety
repayment and cash settlement remain directly callable.

The UI and other callers must adopt this execution envelope before controlled
public deposits are opened. Return values added to maintenance functions report
useful work; selectors are unchanged, and clients that ignore transaction return
data continue to work.

## Keeper economics and redundancy

The keeper previews each write and skips successful zero-work results. The
synthetic peg tops up to a 50bp buffer when less than 25bp remains, avoiding a paid
top-up for every tiny interest increment. Clearing a completed source safety
commitment counts as work so optional ramping cannot remain stuck behind it.

Harvests use measured PRIME volume and oracle prices to compare conservative
estimated gas cost with gross yield converted. The default scheduling examples
are a $1 minimum and gas ≤10bp of gross harvest value. A 24-hour maximum batching
wait after the previous successful harvest, or $10-equivalent outstanding Main
interest, bypasses the economic delay when a safe harvest is available. The
interest threshold values HOLLAR at par, matching the strategy's existing debt
convention. These operator settings cannot bypass on-chain minimums, budgets,
expiry, source harvestability or swap floors. They do not promise a harvest when
the strategy lacks safely realizable yield.

Every optional buy/harvest uses the controller's pinned preview and quotes with
2bp quote-to-inclusion tolerance by default. This is additional protection; it
never widens the independently configured oracle tolerance. Estimates and fee
quotes retain their 20% margins and the native transaction gas ceiling.

Servicing quotes allow up to twice the observed input to accommodate interest
accruing before inclusion, with the output floor scaled by the same factor.
This preserves the quoted unit price and remains inside the configured trade
and volume limits. Primary buy/harvest inputs keep their measured caps. A newly
required, previously absent service leg still requires a refreshed preview.

Source safety runs before optional trades. Peg checks run each cycle. A separate
30-second read loop monitors source HF, Main backing, interest, synthetic coverage,
stale RPC heads and stuck receipts even while a transaction is awaiting inclusion.
RPC failure after submission keeps the signer locked until a receipt is observed;
there is no blind retry with another nonce.

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
   lane sizes, shared directional budgets, refill rates and policy expiry.
2. Register only `deposit(uint256,address)` and `rebalance()` on each vault,
   `pokeBorrow()` on the source, and `harvest(uint256[])` on the Harvester. Bind
   the same controller to all of them.
3. Set `EXECUTION_CONTROLLER` and an oracle-listed `GAS_ASSET_ADDRESS` in each
   keeper. Set `RPC_URLS` to the operator's comma-separated RPC endpoints; use
   independent infrastructure across operators. Approve batching/urgency settings.
4. Supply `PROPELLER_EXECUTION_CONTROLLER` and `PROPELLER_EXECUTION_POLICY` to
   `verify-readiness.ts`. The latter JSON has `maxQuoteAge`, `maxQuoteBlocks`,
   `budgets: [{group, capacity, refillPerSecond, expiresAt}]` and
   `limits: [{lane, group, minimum, maximum}]`, with base-unit integer strings.
   Obtain lane IDs from `controller.lane(consumer,input,output)` and compare the
   actual wiring against the approved governance payload.
5. Complete a quote-aware UI deposit, partial harvest with Main servicing,
   expired-policy rejection, keeper handover and safety/exit rehearsal on the
   exact deployment. Public activation still needs approved liquidity/refill
   limits, recovery funding and independent review.

The controller does not implement deposit/exit matching, a collateral admission
queue, automatic treasury funding, a provider replenishment service or a revised
source-loss policy. Those must not be assumed in return estimates.
