# Main Interest: Policy Comparison

Historical policy-selection evidence. The selected policy is now implemented in
[Main servicing and the operating buffer](operating-buffer.md); the alternatives
below remain economic models, not additional deployed contract implementations.

Simulation and analysis performed locally on 2026-09-22, without production
contract changes or transactions. This compares proposed policies; it does not
implement them or approve production deployment. See the [current status and
resource index](README.md) for the publication checkpoint.

The separate [HOLLAR peg-liquidity analysis](hollar-peg-liquidity.md) addresses
pool depth, finite HSM funding and facilitator burn capacity. The constant
conversion-cost assumptions here do not establish that those markets can
execute at the modeled price or maintain the peg.

## Recommendation

For an RC, prefer **periodic Main debt servicing from fresh harvested yield,
plus a separately accounted HOLLAR buffer for interest during settlement and
priced exit costs; compound the remainder into ETH/tBTC**.

This is a refinement of the earlier harvest-only proposal. Harvest-only leaves
interest accruing after the last harvest and during unwind. An interest-only
buffer also fails to cover execution losses on the much larger gross PRIME sale.
Neither "always pay at harvest" nor "always pay at withdrawal" is a universal
return winner.

Withdrawal-time servicing is a viable alternative when maximizing exposure to
ETH/tBTC is the priority. It performs better in the selected bull path and uses
fewer reverse swaps, but needs reviewed position-level principal/yield accounting,
net-debt share pricing, and executable yield sales at exit. The current contracts
do not have that implementation. It brings forward accounting deliberately
deferred for manual recovery.

The proposed buffer belongs to users, not the treasury. It is funded only from
eligible fresh yield, distinct from protocol fees and the collateral rounding
reserve. It is not a promise that yield covers permanent strategy losses.
Unspent amounts remain part of holder backing. Governance recovery remains the
backstop; a short claim remains pending without funding, never haircut.

Seven days and 10 basis points below are **sensitivity inputs, not recommended
production defaults**. Choose the budget from measured unwind time, stressed
borrow rates and executable routes. A yield-funded buffer is initially empty;
early exits can need explicit bootstrap funding before sufficient yield exists.

## What Was Compared

| Policy | During operation | At exit |
| --- | --- | --- |
| Current flow | Compound all after-fee harvest; existing source/cash backing guard | Promise gross collateral; missing HOLLAR needs external funding |
| Harvest service | Pay the Main repayment gap from fresh after-fee yield; compound the rest | Do not sell previously compounded yield; any remaining gap needs funding |
| Withdrawal service | Compound all after-fee harvest; recognize eligible yield as debt backing in a NEW check | Sell only the exiting holder's yield, not principal; fund any residual gap |
| Buffered service | Harvest service plus a seven-day HOLLAR interest budget | Allocate reserve pro-rata to each exiting slice; refund unspent backing |

Additional buffered-service runs reserve 10/20/50bp of gross PRIME exposure for
exit costs while charging 10bp execution cost. The fee basis is identical in all
policies: **5% of collateral actually received after the harvest conversion,
before Main servicing**. There is no automatic treasury fee sweep.

An ordinary HOLLAR position owes both borrowed principal and accrued interest;
extra collateral increases borrowing capacity, not repayment proceeds.
[Hydration's HOLLAR documentation](https://docs.hydration.net/products/hollar/).
The simulation uses the pinned RPC rate below, not the different APR examples
in that documentation.

## Inputs and Scope

Fresh read-only snapshot from `hdx.tarn.hydration.cloud`, block **14899895**,
hash `0x79c394d40e38b07b8c9e3cb09139b606e40a4cabe0a37729366acb6e2f2b34f3`.
HOLLAR variable borrow APR was **4.4016888918%**, ETH LTV 75%, tBTC LTV 80%,
PRIME liquidation threshold 88%, and the modeled loop target HF is 1.05.

- **720 main cases:** six initial TVLs ($100k, $500k, $1m, $10m, $50m, $100m),
  five price/rate paths, four policies, 0/50/100% Main discount, with/without a
  30-day keeper outage. Initial collateral is 50/50 ETH/tBTC in USD.
- **460 sensitivity cases:** collateral conversion cost, gross PRIME route cost,
  harvest frequency, settlement delay, buffer duration, exit-cost reserve and
  early exits. These vary one factor or an explicitly identified pair of factors;
  they are not a complete Cartesian stress matrix.
- 90 daily operating steps; half exits starting day 60, the rest day 90.
  Requests are assumed submitted 12 hours before these starts. A default three-day
  unwind-interest stress is charged to each exiting slice, including after day 90.
  It does not become the remaining holders' liability in the model.
- Flat control; bull ends ETH 2x/tBTC 1.6x; bear ends 0.3x/0.4x; seesaw ranges
  0.68x-1.4x; rally/crash peaks at 1.5x/1.3x on day 45 then ends 0.3x/0.4x.
- Hypothetical PRIME gross APR: 6.5% flat/bull, 4% bear, 5.5% seesaw. Borrow APR:
  snapshot rate flat/bull, 12% bear, alternating 2.5%/12% seesaw. Rally/crash
  switches from bull rates to bear rates after day 45. These are not forecasts.
- Default collateral conversion friction is **10bp per conversion**, including
  the reverse collateral-to-HOLLAR conversion. The comparison initially excludes
  source entry/unwind friction to isolate interest policy, then explicitly adds
  **10bp of gross PRIME trade volume** in a separate sensitivity.
- The source cost basis must be recovered before harvesting new surplus. The
  existing 0.1% harvest threshold means daily checks do not imply daily swaps.

The borrowing equation always uses **debt including accrued interest**:

```text
additional borrow = max(0, collateral value * LTV - current Main debt)
```

Existing 5/3 percentage-point rebalance bands are included. The withdrawal policy
needs a changed backing check that can count safely spendable yield. The other
policies keep the source/cash check. Therefore policy results also include the
effect of blocked or enabled resizing, not just the cost of a swap.

## Results at $100k

No outage, no Main discount, default conversion friction, zero source-route
friction, three-day exit stress. The same proportions scale to other TVLs in
this constant-cost model, but native liquidity and caps do not scale that way.

**User collateral gain**, expressed relative to initial deposited ETH/tBTC units,
weighted at their initial prices. These are 90-day cohort returns with a half
exit on day 60, **not APY**, and do not count asset-price appreciation as yield.
Full payouts below are conditional on the explicit funding in the next table.

| Market path | Current | Harvest service | Withdrawal service | Seven-day buffer |
| --- | ---: | ---: | ---: | ---: |
| Flat | 2.6252% | 1.9235% | 1.8919% | 1.8953% |
| Bull | 1.9901% | 1.8571% | 1.9550% | 1.7982% |
| Bear | 0% | 0% | 0% | 0% |
| Seesaw | 0.3139% | 0.2764% | 0% | 0.2341% |
| Rally then crash | 1.3144% | 1.1083% | 0% | 1.0260% |

**External HOLLAR needed to complete those payouts:**

| Market path | Current | Harvest service | Withdrawal service | Seven-day buffer |
| --- | ---: | ---: | ---: | ---: |
| Flat | 732.52 | 28.04 | 0 | 0 |
| Bull | 732.52 | 46.31 | 0 | 0 |
| Bear | 5,565.91 | 5,565.91 | 5,565.91 | 5,565.91 |
| Seesaw | 1,630.99 | 1,583.48 | 1,252.31 | 1,536.24 |
| Rally then crash | 3,132.65 | 3,119.39 | 2,550.13 | 3,031.77 |

The first table alone is misleading. Current flow looks best in flat markets
because governance pays all Main interest while users keep the gross yield.
Harvest/buffer policies also preserve already-compounded yield in these runs;
withdrawal service explicitly spends it. In seesaw, the buffered policy's
1,536.24 HOLLAR funding falls to a theoretical **1,255.60** minimum if governance
also extracts all eligible retained yield. That manual recovery mechanism is not
implemented here. It must not be confused with an automatic user haircut.

For an additional economic comparison, the output subtracts funding translated
into collateral at each exit price. This is labeled **unsubsidized token-equivalent
return**, not an authorized payout reduction. Flat results become 1.8927% current,
1.8954% harvest, 1.8919% withdrawal, and 1.8953% buffer. The small differences should
not be overinterpreted given modeled execution and omitted gas.

### What the Paths Show

- **Flat:** buffer and withdrawal servicing have almost identical economic
  returns. Earlier repayment slightly reduces interest-on-interest. With these
  inputs, the buffer's advantage is only about **$3.36 per $100k** in initial-price
  collateral equivalents over the modeled period.
- **Bull:** withdrawal servicing retains more collateral exposure before paying
  a HOLLAR-denominated bill. It earns about **0.157 percentage points** more token
  yield than the seven-day buffer. That is a market exposure benefit, not a free
  accounting improvement or evidence it will win in other conditions.
- **Bear:** there is no positive loop carry to allocate. All policies need
  governance recovery. A yield-funded buffer cannot solve persistent negative
  carry when no yield is generated.
- **Seesaw:** timing, carry losses and the inability to harvest below source cost
  basis dominate. Withdrawal service spends accrued yield and so reports less
  user yield and a smaller governance cheque. Retaining yield while subsidizing
  debt is not a superior strategy return.
- **Rally/crash:** accumulated collateral yield loses HOLLAR purchasing power.
  The minimum principal-support figures are approximately 2,213 HOLLAR current,
  2,344 harvest, 2,550 withdrawal, and 2,314 buffer. Current flow also had less
  exposure because its backing guard blocked upward resizing. This is a policy
  feedback effect, not proof that disabling debt service is the safest design.

## Sensitivities That Matter

### Exit Execution Costs

An interest-only buffer is insufficient once source unwind friction is included:

| $100k case, 10bp gross source-route cost | User token gain | External HOLLAR needed |
| --- | ---: | ---: |
| Flat, withdrawal service | 0.9469% | 0 |
| Flat, seven-day interest-only buffer | 1.3380% | 387.39 |
| Flat, seven-day buffer + 10bp exit-cost reserve | 0.9500% | 0 |
| Bull, withdrawal service | 0.8162% | 0 |
| Bull, seven-day interest-only buffer | 1.1154% | 718.80 |
| Bull, seven-day buffer + 10bp exit-cost reserve | 0.5764% | 0 |

The higher apparent return of an under-reserved buffer is paid for by the treasury.
In the cost-reserved flat case, average HOLLAR reserve is about **278**, peak
about **545**, per $100k initial collateral. Bull average is about **361**, peak
**807**. These budgets can only be accumulated after enough yield exists.

Increasing the budget to 20/50bp reduces bull token yield further in this model.
Do not reserve an arbitrary large amount without measuring its opportunity cost;
do not assume the illustrative 10bp is an executable production unwind quote.

### Early Exits and Slow Unwinds

With the 10bp exit-cost reserve, a flat-market half-exit starting on day 1, 3 or 7
still requires about **476.53 / 449.59 / 395.60 HOLLAR** respectively. Later
harvests cannot retroactively fund that exit. Initial capital/funding and admission
policy must be explicit; none is supplied invisibly by this simulation.

Without source friction, extending the bull exit stress from 3 to 14 days leaves
about **108.09 HOLLAR** unfunded by a seven-day interest buffer. A one-day buffer
also fails the default three-day exit. A buffer is a finite budget, not a payout
deadline or an alternative to freezing during an incident.

### Discount, Outage and Execution Frequency

At 100% effective Main discount, profitable flat/bull cases converge across
policies when source-route friction is excluded. Loop borrowing is still charged;
the bear case still needs about **4,186.18 HOLLAR** recovery per $100k.

A 30-day keeper outage still accrues interest and loop carry. It can delay resizing
and compounding, worsen recovery needs, or in a deliberately simplified flat
model retain profitable unharvested carry. The model has no liquidation engine:
an occasional improvement during an outage is not evidence outages are safe.

Baseline flat/bull harvest/buffer servicing uses **60 reverse swaps** across the
two vaults, versus **4** for withdrawal servicing. Weekly checks reduce the flat
buffer to 24 reverse swaps. Executing a service inside harvest need not mean a
separate transaction, but it still adds execution work. Gas is not charged to
depositor principal or assumed to be a known USD fee.

At $100k, only about **$0.06 incremental execution cost per extra reverse swap**
would erase the flat case's $3.36 buffer advantage over withdrawal service.
This is a break-even sensitivity, not a measured Hydration fee. The nominal
break-even scales with TVL under constant trading costs, while real price impact
can reverse that scaling. Batching and the final adapter matter.

## Implementation Tradeoffs

| Concern | Harvest plus costed buffer | Withdrawal-time yield sale |
| --- | --- | --- |
| ETH/tBTC exposure | Lower while cash is reserved | Higher; can help in bull, hurt in crash |
| Swap count | More frequent, can batch | Fewer, larger exit-time sales |
| Exit dependency | Prefunded up to a finite budget | Depends on available yield, price and route at exit |
| Prior user collateral | Never sold by ordinary servicing | Must distinguish principal from eligible yield |
| Required new accounting | Fresh-yield allocation, reserve ownership, debt/queue reconciliation | Principal attribution, net share pricing, yield-sale authorization, debt/queue reconciliation |
| New deposit fairness | Clear or reserve existing costs before accepting new liability | Price outstanding costs into entry; do not spend a late depositor's principal |
| Insolvency | Freeze/recover; no automatic haircut | Freeze/recover after eligible yield is exhausted |

Neither approach is a one-line change. Both must allocate post-start interest to
the correct exit, handle partial claims, discount changes and actual repayment
amounts, and avoid double-crediting payments in `totalQueuedDebt`. A HOLLAR
reserve must be owned and accounted for, not treated as ownerless donated cash.
The current CollateralVault has only **66 bytes** of EIP-170 headroom, so the
implementation likely needs a reviewed external module and small vault hooks.

My preferred next step is to design that buffer/servicing accounting, then test
it with the production adapter and measured costs. Choose withdrawal-time
deduction instead only with an explicit decision to implement the additional
principal/net-yield accounting now. No implementation choice has been applied.

## Verification and Limitations

The separate model checks the cash conservation identity after every daily step:

```text
collateral value + source equity + HOLLAR reserve - Main debt
  = initial capital + collateral price P&L + PRIME income
    - loop interest - Main interest - fees - execution costs
    + explicit governance funding - payouts
```

All 1,180 economic runs satisfy the identity within floating-point tolerance.
Maximum observed absolute residual is below $0.000001. This is economic-model
precision, not a token-unit contract rounding guarantee. Principal preservation
is imposed by a per-cohort ledger and explicit funding; it is not proof that
an unimplemented contract path preserves principal.

**21 new model tests passed.** Three new Solidity regressions demonstrate the
current code's headroom calculation, collateral-yield/backing distinction, and
gross-yield exit promise needing HOLLAR funding. Together with one inherited
fixture test, the focused suite has four passes. Full Forge suite: **231 passed,
0 failed, 3 skipped** across 35 suites. The existing eight pressure-model tests
pass against both September 18 and September 22 snapshots. All production
contract runtime artifacts remain unchanged.

Limits:

- No production servicing controller, principal ledger, treasury extraction or
  automatic buffer was added. No new native-policy campaign was run.
- Source sleeves are attributed per vault with simplified target leverage and
  daily accrual, not the exact shared-loop share allocation, Aave debt-index,
  liquidation or per-block unwind engine. The 12h cooldown is an assumed request
  schedule, not a new timing proof. Exit-delay stress locks the source quote and
  collateral price while charging additional Main interest; it does not model
  further price changes or PRIME carry during that settlement interval.
- Holder transfers, late deposits and incident allocations are not simulated as
  full lifecycle paths. Withdrawal-policy principal attribution is an explicit
  assumption; the unit test shows why a late deposit cannot inherit old yield,
  not that the required transferable-share accounting has been implemented.
- Trading costs are sensitivities, not real-route quotes. Model capacity flags
  are conservative sums of per-vault exposure peaks, not a live market simulation.
  $500k+ full-target cases still exceed the snapshot HOLLAR mint headroom of
  approximately **1.369m HOLLAR**. Larger cases also exceed other reserve caps.
- Even $100k is not asserted deployable. The updated official stable-swap math
  check at stored snapshot pegs finds no positive aggregate entry within the
  hypothetical 1% oracle floor; the earlier September 18 positive amount is stale.
  Actual runtime peg updates and routes need execution verification. The old test
  was corrected to validate quote behavior instead of assuming capacity stays
  positive. This reinforces that these policy returns are not a yield forecast.

## Reproduce

From the repository root:

```sh
node scripts/propeller/interest-policy-model.mjs \
  /tmp/propeller-market-snapshot-20260922.json \
  /tmp/propeller-interest-policies-20260922.json

PROPELLER_MARKET_SNAPSHOT=/tmp/propeller-market-snapshot-20260922.json \
  node scripts/propeller/interest-policy-model.test.mjs
```

From `propeller-vault` with this workspace's linked dependencies:

```sh
FOUNDRY_ALLOW_PATHS='["/home/mrq/git/money-market/hdcl-vault/lib"]' \
  forge test --offline --evm-version london --match-contract InterestPolicyEvidenceTest -vv
```

Results: `/tmp/propeller-interest-policies-20260922.json` contains the complete
main matrix, sensitivities and per-vault exit accounting; the matching `.csv`
contains main comparison rows. Logs are `/tmp/propeller-interest-evidence-20260922.log`
and `/tmp/propeller-interest-full-suite-20260922.log`. Updated source-pool/HSM
pressure checks are in `/tmp/propeller-pressure-results-20260922.json`.

For the earlier contract/native campaign and its different funding assumptions,
see [90-day readiness and pressure report](market-stress-90d.md).
