# Principal Preservation

For the new Main-interest policy, debt-cohort accounting and current verification,
see [operating buffers](operating-buffer.md) and [the candidate report](operating-buffer-verification.md).
The dated test/deployment sections below are historical evidence.

## Required Policy

The user's deposited collateral must not be used to absorb strategy losses.
Principal is denominated in the deposited asset, not its dollar value. A delay
in withdrawal does not authorize reducing or closing the unpaid principal claim.
Reconfirmed on 2026-09-18: proportional emergency recovery changes payment
timing only, never the total principal owed. If 40% of principal has been paid,
the remaining 60% is still owed in the same collateral asset; it is not a
finalized loss. Governance must fund the shortfall when recovery is needed.
Preserving a snapshotted redemption amount is insufficient if share conversion,
rounding, or earlier accounting already reduced the position's principal claim.

Confirmed requirements:

- No automatic write-off of debt, dust, or unpaid principal claims because an
  unwind stops making progress or temporarily lacks health-factor headroom.
- Block new deposits while the vault is underfunded. A new depositor is not a
  recovery fund for an existing deficit.
- Fees apply only to harvested collateral yield, never deposited principal.
- Yield is not guaranteed: already-harvested and compounded yield may cover
  strategy losses, but original deposited-asset principal must remain intact.
  Yield-loss accounting must be explicit and fair across affected holders.
- Governance funds bootstrap shares before public deposits open.
- Governance funds recovery when needed. No dedicated pre-funded reserve or
  automatic treasury payment for strategy losses is required by this policy.
  A separate collateral dust buffer funds arithmetic rounding only; it is not
  a HOLLAR strategy-loss reserve.
- Keep partial claims active until all unpaid principal and any retained yield
  entitlement are paid. Yield allocated to cover losses under the approved
  policy must be separately recorded, never disguised as a principal write-off.
  Settlement and claiming may be called separately.
- An unexpected unwind must distribute available recovery fairly, not reward
  users for being online first or submitting their withdrawal first. Include
  all affected holders automatically, even without a withdrawal request, with
  the same proportional recovery as funds become available. This is a required
  change; the current local FIFO settlement does not satisfy it.
- Emergency allocations may be indexed off-chain and settled manually through
  a governance proposal, including treasury use of compounded user yield. A
  built-in automatic pro-rata recovery engine is not required. The immediate
  contract requirement is the ability to stop withdrawals, including claims
  already settled before the emergency freeze.
- Withdrawal requests have a configurable cooldown, initially 12 hours, before
  their unwind can start. This is not merely a delay before paying an already
  unwound request. Independent safety deleveraging must remain available.

## Loss Allocation: Yield at Risk, Principal Protected

Confirmed on 2026-09-18: under the intended architecture, liquidation risk is
confined to the PRIME loop. A loop liquidation reduces the assets backing Main
HOLLAR borrowing; it does not cancel that Main debt. The resulting HOLLAR
funding shortfall may be covered by eligible user yield, including compounded
yield. Any residual shortfall is the protocol's recovery obligation, not a
principal haircut. Governance provides missing HOLLAR without selling users'
principal collateral. Users retain their full deposited-asset principal entitlement,
less principal already returned. "Users lose nothing" refers to preservation of
that token amount, not protection against its market-price changes or a promise
of uninterrupted withdrawal liquidity.

Emergency distribution therefore allocates available repayment liquidity and
releases user collateral fairly; it must not allocate strategy losses to users'
principal. Offline holders have the same entitlement to recovery. Protocol fees,
strategy losses, and rounding must not silently consume deposited principal.

Confirmed on 2026-09-18: already-harvested and compounded yield may cover losses,
provided original deposited principal remains intact. For a position with no
prior withdrawals or transfers, 1 ETH deposited plus 0.1 ETH of retained net
yield permits at most 0.1 ETH of yield to cover losses; the 1 ETH principal
remains owed. Governance need not restore yield consumed by losses or foregone
future yield. This does not authorize any live recovery transfer now.

Principal and loss-absorbing yield require separate position-level accounting,
including partial withdrawals, queued redemptions, and share transfers. Under
the chosen manual recovery model, this accounting may be reconstructed by an
indexer and approved through governance rather than maintained by a new on-chain
principal ledger. Its correctness is a governance and review responsibility,
not a principal guarantee independently enforced by an indexer. An
aggregate vault principal floor is insufficient: a later user's new deposit is
fully principal, even if older positions have accumulated yield. Transferring or
splitting shares must not create new principal guarantees or let a position
avoid its fair yield-loss allocation. The implementation must not use a reduced
total share price as a substitute for protecting each position's principal.

The treatment of yield already settled but unclaimed, the incident cutoff, and
the attribution of partial payments between principal and yield still require
an explicit accounting design. Prior executed payments cannot be clawed back.
Existing treasury fee entitlements are separate; allowing depositor yield to
cover losses does not automatically divert accrued protocol fees. Treasury-owned
fee income or other treasury assets can be a voluntary recovery funding source,
subject to the treasury's applicable spending authorization.

This is the required risk allocation, not proof that Main liquidation is
structurally impossible in the current contracts. Production must verify that
Aave counts the synthetic collateral, that its oracle value and liquidation
threshold maintain the Main health-factor floor, and that this remains true
through interest accrual, keeper outages, parameter changes, and recovery.
`maintainPeg` tops up synthetic collateral but does not repay HOLLAR debt or
generate recovery funding. A source liquidation must not disable this protection.

## Governance-Funded Recovery

Confirmed on 2026-09-18: permanent strategy deficits are funded by governance
when needed, rather than by a dedicated reserve contract. Funding is an explicit
governance action; this decision does not authorize any transfer now.

Until recovery is funded, preserve every unpaid principal claim and block
underfunded entry. Only the separately identified yield component may be reduced
to cover losses. Withdrawals may wait for governance approval and execution;
there is no fixed repayment deadline or automatic liquidity guarantee.

Governance supplies HOLLAR to the affected SubLoop and/or Main vault according
to their separate outstanding obligations. A source top-up alone need not cover
Main interest or a Main debt deficit. Recovery funding mints no depositor shares.
Normal repayment and settlement remain permissionless, with owner-authorized
claims. Emergency withdrawal and allocation paths must respect the new freeze;
governance settlement must not require reopening the normal FIFO queue first.
Entry remains subject to the normal backing checks and pause flags, not merely
to a governance recovery announcement. Protocol fee collection and treasury
claims are unchanged; fees are not automatically diverted into recovery.

Treasury may elect to fund the HOLLAR shortfall using its own accrued fee income
or other assets. This is optional funding, not a mandatory reserve or automatic
fee sweep. In the current fee controller, anyone may call `claimProtocolFees`,
but the assets always go to the configured recipient; the caller cannot redirect
them. Fees accrue in the actual collateral assets, so treasury must obtain
HOLLAR through an explicitly authorized conversion or use existing HOLLAR before
funding the affected Main vault and/or SubLoop. Treasury spending authority is
distinct from permissionless fee claiming and recovery settlement. No transaction,
recipient change, or transfer is authorized by this design note.

## Withdrawal Cooldown: Default and Timing Confirmed

Confirmed on 2026-09-18: the delay is configurable, defaults to 12 hours
(`43_200` seconds), and must elapse BEFORE starting the requested unwind.
The earlier suggestion to unwind during the waiting period is superseded.
Normal flow: request and escrow, wait, initiate unwind, settle, then claim.
Twelve hours is the earliest unwind eligibility, not a guaranteed payout time.
The cooldown is implemented locally; verification is recorded separately below.

Local implementation semantics:

- Governance configures the duration per vault with `setWithdrawalDelay(uint32)`.
  Zero disables the wait for future requests. Each new request records an immutable
  `unwindEligibleAt = request timestamp + withdrawalDelay`; later configuration
  changes apply to new requests and do not change existing eligibility times.
- Escrow the requested shares immediately, but do not call
  `yieldSource.requestUnwind` for that request during cooldown. No source share
  burn, withdrawal-driven unwind target, repayment allocation, or user payout
  may be triggered for it before eligibility. Even already-available HOLLAR
  must not provide a fast payout bypass.
- A permissionless keeper action starts an eligible request's unwind exactly
  once, provided emergency recovery has not frozen it. The existing gradual
  unwind and settlement follow; there is no second 12-hour delay after unwind.
  New requests, including requests from an approved spender, start their own
  timers. Splitting requests or changing a payout receiver cannot bypass them.
- Independently required safety deleveraging and Main synthetic-floor
  maintenance remain available during cooldown. The delay gates user-requested
  exits, not risk reduction of the shared strategy. Existing eligible requests
  may continue to unwind unless frozen.
- Emergency freeze overrides elapsed time: block starting eligible unwinds and
  paying claims, including requests already eligible or settled at the incident.
  Reopening normal FIFO must not bypass the approved recovery allocation.
- Verify the chosen 12-hour window against operational detection and pause
  execution time. It cannot stop an already-eligible request before freezing,
  reverse prior payments, or protect against an incident that stays undetected.

Waiting requests escrow vault shares but remain part of live invested supply.
They continue to share yield and Main interest until `startUnwinds(maxRequests)`
snapshots the position at eligibility. No source shares are reserved or burned
on request; quoting the actual slice at start avoids double reservation and
allocating cooldown interest solely to non-withdrawing holders. `queueUnwind`
separates waiting from started requests; `totalQueuedShares`, collateral and debt
track started requests only. Before start, a request's `collateralOwed` and
`debtShare` are zero, not a finalized zero entitlement. Once started, the existing
fixed collateral promise and partial-claim accounting apply. Interest accruing
AFTER start is assigned to the exit's own HOLLAR buffer and live debt units; it
cannot consume remaining holders' cash. See [Main servicing](operating-buffer.md).
Exhaustion preserves unpaid claims and still needs explicit recovery funding.
The keeper reads chain time and starts bounded batches of up to 16 requests.

Verify no request-driven source activity before eligibility, just-before and
exact-eligibility boundaries, idempotent start, multiple waiting requests,
staged partial claims, funding-before-eligibility, duration changes, splitting,
freeze before/after eligibility, FIFO behavior when durations change, continued
safety maintenance, rounding, and deployment size. The ABI bounds the delay to
uint32 seconds; governance is trusted to choose an operationally suitable value.

## Manual Emergency Recovery: Deferred Until Needed

Latest user decision on 2026-09-18: defer the recovery indexer, allocation
accounting, and bespoke governance payout implementation until an incident
actually requires them. Their advance implementation is no longer a launch gate.
The fairness/principal requirements below remain the policy for any future
recovery. Freeze exits while the incident-specific calculation is prepared;
deferral can extend the withdrawal pause. Do not reopen FIFO against partial
funding as a substitute for fair recovery. The new E2E models test full backing
restoration before reopening, not an unimplemented partial-payout mechanism.

Confirmed on 2026-09-18: first-arrival priority is not acceptable for an
unexpected unwind. Include every affected holder automatically, even those who
have not requested withdrawal, with each receiving the same proportional
recovery as funds become available. Eligibility must not depend on submitting a
request, joining a recovery queue, or being online during the incident. Reserve
offline holders' allocations; claiming earlier must not increase entitlement.
Governance may calculate the allocation off-chain and execute manual settlement
through a proposal. Treasury may manually extract approved compounded user
yield for recovery, not just its own protocol fees. These decisions supersede
the earlier suggestion to require a built-in automatic recovery allocation
engine. They do not authorize arbitrary principal withdrawals or a live action.

The current vault settles FIFO. SubLoop `_creditFreed` already distributes
proportionally among remaining open unwind requests, but does not reserve funds
for vaults that have not requested an unwind. Fairness therefore requires both
source-level and vault-level reconciliation. Under this design it is performed
for the governance-approved recovery plan, not necessarily by new persistent
on-chain allocation logic.

The cooldown and freeze controls below are implemented locally. If an incident
requires indexed allocation, its calculation and execution must address:

- Freeze affected vaults before preparing the recovery proposal: block new
  `requestRedeem` calls, `claim` payouts including previously settled claims,
  and normal FIFO allocation in `pokeSettle`. Block deposits and new leverage
  as part of the incident procedure. Merely pausing the keeper is insufficient;
  these operations are callable by anyone directly on-chain.
- `SubLoop.pauseEmergency()` lets a guardian freeze every attached vault without
  iterating over holders or depending on positive source equity. Governance's
  `ADMIN_ROLE` alone can call `unpauseEmergency()`. Vault `paused()` includes
  this source flag; local unpausing cannot bypass it. Local vault pause remains
  available, with local reopening also restricted to `ADMIN_ROLE`. Production
  wiring must assign the actual technical committee's guardian authority.
- Preserve Main synthetic-floor maintenance and safe debt reduction while exits
  are frozen. Do not blindly disable debt servicing when blocking `pokeSettle`;
  it currently combines Main deleveraging with FIFO allocation. A broken swap
  route may still require a separate source pause. Update keeper behavior too.
- Choose a canonical snapshot at freeze and index all affected holders, including
  those without redemption requests. Reconcile deposits, transfers, escrowed
  shares, prior partial payments, settled balances, and source/Main debts.
  The token hook freezes user share transfers during the incident;
  old shares and queued claims must not survive as duplicate payout rights.
- Governance reviews each position's protected principal, eligible yield, yield
  contribution, and funded payout. Apply the same proportional recovery policy
  across holders and reconcile cross-vault HOLLAR allocations and ongoing
  interest. An aggregate surplus figure alone cannot protect each depositor.
- Execute the approved yield withdrawal, conversion, funding, and settlement via
  a narrowly scoped governance recovery entry point or an audited one-off UUPS
  upgrade. The current vault has no generic treasury extraction function. A
  proposal cannot withdraw vault-owned assets merely by calling Aave from the
  governance account. Choose and rehearse an executable path before using it
  to make incident-specific payouts or extract user yield.
- Preserve all unpaid principal and reserve offline holders' allocations across
  staged settlements. For principal claims of 10 ETH and 20 ETH, 40% cumulative
  recovery allocates 4 ETH and 8 ETH, independent of who claims first. Prior
  payments and credits must be reconciled without double payment; executed
  transfers cannot be clawed back. Governance funds any remaining principal
  deficit rather than closing it as a loss.
- Reconcile or retire old shares, queue entries, and source claims consistently
  with the approved allocation before normal operation can resume. Executing a
  transfer list without adjusting those liabilities is not a complete settlement.
  Keep incomplete recovery frozen rather than reopening FIFO against partial
  funding. No incident payout deadline is imposed by the current policy.

Open design details include the snapshot cutoff and reconciliation procedure,
cross-vault weights, treatment of settled yield and prior credits, partial-payment
basis, the execution mechanism, and conditions for reopening or closing a vault.
Manual governance recovery deliberately trusts the indexed calculation and
approved execution; it is not an on-chain proof of each holder's principal floor.
Independent reconciliation is required before executing such a recovery.

A manual freeze cannot undo exits completed before activation or prevent all
front-running of a pending pause. A full governance vote is too slow to serve as
the only incident stop mechanism. Local vault `pause()` now stops requests,
unwind starts, FIFO allocation, claims and ERC20 share transfers. `pokeSettle`
remains callable to repay an already-committed Main deleveraging target, but
does not allocate user payouts while frozen. `maintainPeg()` remains available.
Source emergency mode stops ordinary unwind selling and new risk, but permits
safety deleveraging without crediting new user exits. Source `pause()` remains
a separate kill switch for ALL route execution, including safety swaps.

Required verification includes permuted request/claim/vault-processing order,
an offline holder with no withdrawal request, split requests and transfers,
multiple vaults, pre-existing partial settlements, staged governance top-ups,
zero-equity entry, interest accrual, rounding conservation, bounded gas, and
native deployment size. Freeze tests must cover direct non-keeper callers,
already-settled claims, authorization, affected-vault coverage, and continued
Main protection. Proposal/indexer tests must cover deposits at different share
prices, partial withdrawals, transfers, repeated loss events, and inability to
consume another position's principal. The cooldown and freeze tests below do
not establish fair emergency distribution; the indexed recovery calculation and
execution still need separate verification. Normal post-cooldown settlement
remains FIFO outside emergency recovery.

## Local Remediation

Branch: `fix/propeller-accounting-readiness`, based on
`7a7f2cf197afb5c4721e19bd061e78bc551b0dd0`. Not published.

Vault accounting separates live shareholder backing from queued collateral,
including settled-but-unclaimed balances. Main repayments use the actual pool
return and a live synthetic/debt ratio. Down-rebalance commitments are excluded
from later redemption snapshots. Rebalancing waits for pending exits and
deleveraging; this does not disable independent SubLoop safety repayment.

SubLoop prices live shares net of outstanding withdrawal liabilities, includes
unreserved HOLLAR cash in equity, enables PRIME collateral on funding, and can
unwind an unlevered position. No-progress calls preserve outstanding claims.

Anyone may transfer HOLLAR to the affected vault and call `pokeSettle` to fund
recovery. Such funding mints no shares and gives the caller no claim. SubLoop
donations can fund its outstanding requests, but a Main debt deficit can exceed
the source's recorded obligation and need separate vault funding.

The keeper services both safety and Main deleveraging without requiring a user
redemption queue. The source's ordinary route pause stops swaps; already freed
funds can still be settled and claimed unless the vault is locally or globally
emergency-paused. Failed synthetic collateral activation reverts deposits.

## Production Gates

Preserving an accounting claim is not proof that repayment is funded. Do not
describe these changes as an unconditional principal guarantee or production
approval. Before release:

1. Operationalize the approved governance-funded recovery policy: deficit
   monitoring, amount and destination calculation, funding source, governance
   execution, and post-funding reconciliation. Rehearse the actual governance
   path; until funding arrives, withdrawals can remain pending indefinitely.
2. Review Main interest funding. Maintaining synthetic collateral protects the
   Aave health factor but does not generate HOLLAR to repay interest.
3. Verify principal conservation through native multi-vault lifecycle and stress
   tests: deposits, interest, swaps, yield fees, queued exits, pauses, partial
   claims, price recovery, and recovery funding. A deployment smoke test alone
   does not establish this.
4. Fund and monitor each vault's collateral rounding buffer. The demonstrated
   deposit/share-conversion loss is addressed by the local changes described
   below; verify the exact production aToken integration and operating budget.
   The source backing view still uses USD8 equity and `negativeCarryBps`; these
   are not exact HOLLAR token-unit solvency checks.
5. Test actual governance and committee execution, revoke deployer authority,
   establish a funded keeper with monitoring, and rehearse incident response.
6. Verify the real swapper and routes, explicit approved slippage, Aave reserve
   parameters and oracle, caps, fee recipient, and discount enrollment.
7. Obtain independent review of the changed accounting. Source parameter bounds,
   bounded queue processing, and liveness under sustained interest remain review
   items; the contract's comments are not proofs of liquidation immunity.
8. Rehearse the implemented withdrawal freeze with production governance and
   committee execution and establish a recovery funding source. The indexed
   principal/yield allocation and bespoke payout proposal are explicitly
   deferred until needed. This does not authorize partial FIFO reopening or
   uncontrolled yield extraction during an incident.

No migration is being provided: Propeller has not been deployed. No live-chain
transactions or remote branch updates are authorized by this local work.

## Earlier Accounting Verification: 2026-09-18

This baseline predates the cooldown and emergency-freeze changes below.

- `forge test --offline --evm-version london -vv`: 153 passed, zero failed,
  three optional fork/formal tests skipped. Solc 0.8.22, optimizer 200, via IR.
- Seven stateful invariants run with 256 sequences of depth 50 each. Every
  sequence starts with successful public funding, avoiding vacuous passes.
- Seven keeper scheduling tests passed; keeper TypeScript build passed.
- Readiness checker typechecks and rejects invalid policy and duplicate vaults
  before contacting RPC. Proposal TypeScript transpiles.
- Fresh native Chopsticks deployment using `wss://hdx.tarn.hydration.cloud`,
  runtime 443, fork block 14729849. All eight deployments succeeded, and runtime
  bytecode and proxy implementation slots match the local artifacts.
- CollateralVault runtime: 24,518 bytes, only 58 bytes below EIP-170. Native
  deployment used 9,057,036 gas. Keep the size regression test mandatory.
- Native fee binding, 5% initial fee, discount installation, enrollment, rate
  change/reset, and synthetic reserve/oracle governance calls succeeded on the
  fork. Governance/committee identities in this harness are test stand-ins.
- Native bootstrap deposit, recognized PRIME collateral, underfunded entry
  rejection, leverage ramp, two queued redemptions, partial settlement, and
  donor-funded full claim repayment passed. Recovery HOLLAR was borrowed by a
  separate donor position through the real Aave Pool, then transferred to the
  vault. The sum paid exactly matched both recorded collateral promises.
- This native scenario did not test a production swapper/harvest fee lifecycle,
  a second public depositor, long-term interest, or autonomous loss recovery.

Fork evidence and transaction summaries are recorded locally in
`/tmp/propeller-readiness-result-20260918.json`. The config and harness scripts
use the `/tmp/propeller-readiness-*20260918*` prefix. No runtime bytecode,
contract-size limit, or gas-limit override was used to make deployment pass.
Chopsticks eventually pruned older receipt lookups; each transaction's success
was checked when submitted. Final runtime bytecode verification is separate
from historical receipt availability.

## Cooldown and Emergency Verification: 2026-09-18

- `forge test --offline --evm-version london -vv`: 173 passed, zero failed,
  three optional fork/formal tests skipped across 31 suites. Solc 0.8.22,
  optimizer 200, via IR, London. Seven stateful invariants ran 256 sequences
  of depth 50 each, including delayed starts and pending-share conservation.
- Boundary tests cover the default 12 hours, zero delay, immutable per-request
  eligibility, delegated/split requests, bounded/idempotent starts, FIFO when
  durations change, and direct funding that cannot bypass cooldown. Waiting
  shares retain their share of yield and debt until start.
- Emergency tests cover already-settled claims, direct callers, share transfers,
  source-wide freezing of two vaults, preservation of an existing local pause,
  guardian/admin separation, and safety debt service without new exit credit.
- Thirteen keeper scheduling tests passed; keeper TypeScript build passed.
  Readiness typechecks and rejects negative, fractional, nonnumeric, and
  overflowing withdrawal delays before RPC. Proposal TypeScript transpiles.
- Final CollateralVault runtime is 23,967 bytes, 609 below EIP-170; SubLoop is
  19,340 bytes. The independent production build matches the test artifacts.
  Custom access-control errors retain the same role checks without embedding
  AccessControl's revert-string hex formatter. No size-limit override is used.
- A fresh local fork uses `wss://hdx.tarn.hydration.cloud`, runtime 443,
  block 14731651. All eight deployments and fee/discount wiring succeeded.
  Native vault implementation deployment used 8,855,370 gas.
  Final deployed runtime bytecode matches the local artifacts, and both proxy
  implementation slots point to the expected implementations.
- Native lifecycle passed: default cooldown left source shares and unwind
  targets unchanged; source emergency blocked matured starts and settled claims;
  Main peg maintenance remained callable; frozen FIFO allocation did not advance.
  After governance reopened and a separate Aave donor position supplied HOLLAR,
  both claims paid exactly their recorded collateral promises: a combined
  10,000,008,140,714,706 ETH base units. This is not a fair emergency-allocation
  rehearsal or proof that yield alone funds repayment.
- The local time advance required advancing the relay-chain slot alongside the
  parachain timestamp. The rehearsal resumed from its verified pre-unwind
  checkpoint after correcting this harness issue, without changing deadlines or
  contract storage. The harness also checks raw ABI-encoded revert reasons.
- Native limitations remain: governance bootstrap/test-role stand-ins, no second
  public depositor, no complete production swapper/harvest fee lifecycle, and no
  long-term interest stress. No contract-size, gas-limit, or bytecode override
  was used to make deployment pass.

Native cooldown/emergency lifecycle and final runtime verification results are
recorded in `/tmp/propeller-cooldown-result-20260918.json`; the local config and
harness scripts use the `/tmp/propeller-cooldown-*20260918*` prefix. This evidence
does not replace the production gates above or prove indexed recovery fairness.

## Funded Principal Rounding

The local fix rounds deposit share issuance and each started withdrawal's
collateral promise up. Rounding costs are paid from `roundingReserve`, not from
the backing of other holders. `fundRoundingReserve(assets)` is a collateral
donation: it mints no shares, grants no repayment right, and remains callable
while paused. The buffer is excluded from `totalAssets`, share pricing, harvest
fees, and user withdrawal entitlements. Ordinary collateral donations still
increase share backing; they do not implicitly replenish this reserved budget.

For old active assets A and shares S, a deposit D receives ceil(D*S/A) shares.
The vault ensures the backing increases by at least ceil(newShares*A/S), using
the buffer to cover any shortfall, including aToken supply rounding. Existing
holders' exact assets/share ratio therefore cannot fall from this operation,
and the new shares' value is at least D. The initial locked shares remain a
separate governance-funded bootstrap expense, not a public depositor's cost.

For a started withdrawal of Q shares, the promise is ceil(A*Q/S). If fractional,
one buffer base unit is released to share backing before reserving that promise;
remaining holders retain at least their previous assets/share ratio. Splitting
requests cannot turn repeated floor-rounding into principal loss. Settlement
also restores any aToken-burn rounding loss from the buffer. Partial claims
retain the existing cumulative accounting and pay the full fixed promise.

Unfunded rounding reverts atomically with `InsufficientRoundingReserve`, including
source share burns and Main repayments in that transaction. Requests and unpaid
claims are preserved for retry after replenishment. The reserve is finite:
each fractional start costs one collateral base unit, deposits may cost up to
one share's collateral value plus supply rounding, and settlements may incur
aToken rounding. Request splitting can consume this funded budget. Monitor it;
do not treat a positive balance as proof of unlimited withdrawal availability.
The readiness checker requires an explicit per-vault funding/alert policy in
native base units, a reserve at least equal to its approved minimum, raw collateral
backing, and an operating margin above the native existential deposit. The shared
policy is also used by proposal generation and keeper monitoring.

Hydration native-token precompiles also enforce an existential deposit when
creating a token account. Keep an operating margin above that balance and review
dust-whitelist protection for custody accounts. Readiness now verifies both using
the runtime's account mapping and dust-protection API. At fork block 14732591,
ETH's existential deposit was 5,373,455,131,650 base units. Initial funding of
1,000,000,000 units failed with `tokens.ExistentialDeposit`; funding twice the
minimum plus that test budget succeeded without overriding the minimum.

`convertToShares` and `convertToAssets` remain conservative floor-valued views;
actual issuance and started promises may be higher because of funded rounding.
No full position-level emergency principal/yield ledger is added. Main interest
funding, source solvency precision, and protection against actual collateral
loss remain distinct from this arithmetic fix.

## Recovery Modeling

`PrincipalRounding.t.sol` checks the 2:1 odd-deposit regression, non-integer share
prices, split/transferred withdrawals, cumulative partial claims, pessimistic
aToken supply/burn rounding, and atomic retry when the buffer is exhausted.
Public users' returned principal is checked with zero rounding tolerance;
existing-holder backing must not decrease. Tests fund the buffer from a separate
donation through the same public entry point used for deployment.

`RecoveryE2E.t.sol` uses both collateral vaults, the shared SubLoop, synthetic,
harvester, and fee controller with modeled Aave/router behavior. It covers yield
and fee accrual, an already-settled but unpaid exit, an offline holder, complete
loss of the PRIME position, an emergency freeze, separately funded Main interest,
partial then full source recapitalization, and reversed processing/claim orders.
Partial funding cannot advance payouts while frozen. After full funding, each
request pays exactly its recorded promise and every public holder receives at
least deposited principal; claims cannot be paid twice. Treasury collateral fees
remain separately claimable and are not silently spent on recovery. A zero-equity
scenario proves waiting shares survive failed unwind starts and can exit after
recapitalization. Fuzzing varies funding fractions and execution order.

These are integration models, not a real Aave liquidation-engine test or proof
of a future indexed proportional payout plan. They neither withdraw user yield
for recovery nor reopen against only partial funding. No recovery indexer,
treasury sweep, new principal ledger, or bespoke governance payout is implemented.

## Rounding and Recovery Verification: 2026-09-18

- `forge test --offline --evm-version london -vv`: 192 passed, zero failed,
  three optional fork/formal tests skipped across 33 suites. Solc 0.8.22,
  optimizer 200, via IR, London. Eight stateful invariants ran 256 sequences
  of depth 50 each, including ring-fencing of the rounding reserve.
- Rounding regression and fuzz tests require exact principal preservation,
  protect existing holders, and cover buffer exhaustion at deposit, unwind
  start, and settlement. Recovery models cover both ETH/tBTC vaults, full PRIME
  loss, interest funding, staged recapitalization, and different exit orders.
- Thirteen keeper scheduling tests passed. The readiness checker typechecks
  and now requires a funded rounding reserve for each configured vault.
- CollateralVault runtime is 24,510 bytes, only 66 bytes below EIP-170;
  SubLoop is 19,340 bytes. Test artifacts match the independent production
  build. The vault implementation deployed with 9,054,108 gas.
- A fresh native Chopsticks fork used `wss://hdx.tarn.hydration.cloud`,
  runtime 443, block 14732591. All eight deployments, fee/discount wiring,
  final runtime bytecode comparisons, and proxy implementation checks passed.
- The native lifecycle funded the buffer through its public function, kept
  it out of share backing, enforced the default cooldown and emergency freeze,
  preserved partial promises, and completed donor-funded repayment through
  the real Aave Pool. Both claims together paid exactly their recorded
  promises: 10,000,008,138,400,895 ETH base units. Three base units of the
  rounding buffer were consumed; the remainder stayed backed and above the
  native token's existential deposit.
- Native limitations remain: governance bootstrap and test-role stand-ins,
  no second public depositor, no native full-liquidation engine scenario,
  no complete production swapper/harvest fee lifecycle, and no long-term
  interest stress. The model tests are not substitutes for these checks.

Native evidence is in `/tmp/propeller-rounding-result-20260918.json`; scripts
and configuration use `/tmp/propeller-rounding-*20260918*`. No runtime bytecode,
contract-size limit, or gas-limit override was used. Historical receipt lookups
were pruned by Chopsticks; each transaction was checked when mined and deployed
runtime bytecode was verified separately at the end. All changes remain local.

## Latest Market and Native Verification

See [90-day pressure and readiness report](market-stress-90d.md) for the completed
rounding-policy tooling, 27 additional long-duration contract scenarios, native
ETH/tBTC two-user lifecycle, and all six TVL pressure levels. The full suite is
now 227 passed, zero failed, three skipped. The production swapper still needs
deployment and verification with Propeller; the native route adapter is test-only.

These tests identify real operating dependencies, not just successful funded
exits: Main interest can block resizing, long keeper outages can erode the
synthetic-only floor, HOLLAR repayment tails require exact reconciliation, and
current PRIME pool/mint capacity does not support unrestricted target leverage.
No additional production Solidity changes were made for that campaign.
