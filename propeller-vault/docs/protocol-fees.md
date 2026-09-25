# Per-vault protocol fees

Fresh-deployment feature. This is not a migration or an authorization to deploy.

Main servicing follows [the yield-funded waterfall](main-debt-servicing.md):
the fee base remains fresh harvested collateral after swaps and BEFORE interest.
Only the after-fee remainder can be converted to HOLLAR for active Main interest;
any remaining collateral is compounded. PRIME retained for future source execution
costs is not yet harvested collateral and is not charged a harvest fee. Treasury fees,
deposited principal and previously compounded collateral are not used by this path.
The fee is a fraction of harvested collateral yield, not of principal or TVL.

## Policy

- Every registered collateral vault starts at **5% (500 bps)**.
- Governance sets each vault independently in `0..10000` bps, inclusive. There
  is no global rate, fallback, inherited default, or additional policy cap.
- The basis is actual collateral received after the harvest swap, before Main
  borrowing interest. SubLoop's own borrowing costs are already reflected in
  harvestable equity. This is not a net-profit fee or loss-carryforward system.
- At 100%, all harvested collateral goes to treasury and none is supplied for
  users. Main borrowing interest still applies, so net user yield can be negative.
- Deposits, principal, withdrawals, collateral price gains, Main aToken interest,
  and caller-funded compound donations are not taxed.
- The current rate applies when previously unprocessed yield is distributed.
  Changing rates does not change already accrued fees.

The borrowing discount is a separate policy: its existing governance/technical
committee authority does not grant fee-setting authority. Governance is the
trusted `DEFAULT_ADMIN_ROLE` holder and can administer roles and the recipient.
The deployer receives no role unless explicitly selected as governance.

## Money flow

```text
SubLoop -> full PRIME balance at Harvester -> pro-rata allocation to each vault
vault -> swap PRIME to its collateral -> measure gross receipts
    fee -> PropellerFeeController (uninvested underlying collateral)
    net -> Main Aave supply (backs user shares)
any caller -> claimProtocolFees(asset) -> current treasury recipient
```

For a 0.01 tBTC harvest at 500 bps, treasury accrues 0.0005 tBTC and users
compound 0.0095 tBTC. Treasury receives neither PRIME nor aTokens/vault shares.
It may later deposit its paid collateral through the ordinary vault workflow.

Fees leave the vault in the compound transaction. They are never included in
user `totalAssets()`. Existing idle collateral, including settled withdrawals,
cannot fund the fee. Same-token compound contributions pass through without a
swap. Other inputs must be received and spent in full; approvals are cleared.
Fee-on-transfer and rebasing tokens are unsupported and balance discrepancies
revert. Swap-reported output is not trusted. Both oracle and caller minimums
apply to **gross** actual output, before the fee. Zero gross output reverts;
positive gross with a 100% fee succeeds without a zero-amount Aave supply.

The Aave-oracle quote calculation lives in the controller to keep the
combined fee/discount vault below EIP-170. Consequently all compounding,
including untaxed donations, requires a registered, wired controller. There is
no fee-disabled fallback during incomplete deployment wiring.

## Controller API

| Call | Authority / effect |
| --- | --- |
| `registerVault(vault, harvester)` | Governance approves the binding; first registration stores 500 bps; rebinding preserves its rate. |
| `protocolFeeBps(vault)` | Explicit stored rate; unknown vaults revert. |
| `setProtocolFeeBps(vault, bps)` | Governance; rejects unknown vaults and values above 10000. |
| `setFeeRecipient(recipient)` | Governance/admin; redirects **all** unclaimed fees. |
| `claimableProtocolFees(asset)` | Aggregate recorded claim for the underlying asset. |
| `claimProtocolFees(asset)` | Permissionless; pays the full recorded claim to the current recipient. No destination argument or caller reward. |
| `validateVault(vault, harvester)` | Read-only readiness check; reverts on unregistered or mismatched wiring. |

Accrual and claim events expose vault, asset, gross output, fee, net supplied,
and actual payout recipient as appropriate. Rate changes include the vault and
old/new bps. Raw collateral donations to the controller are not added to claims.
There is deliberately no admin sweep of reserves backing claims.

Claims are aggregated by asset, not by vault or historical recipient. Two vaults
using the same asset can charge different rates but fund one asset ledger.
An empty claim is a no-op. A failed transfer restores the ledger and does not
block harvesting or other assets' claims. Recipient rotation cannot recover
already paid fees. Zero, the controller itself, and registered protocol custody
addresses are rejected as recipients. Governance must still verify ownership
and token support; address checks cannot prove those properties.

## Atomic harvest

Before harvesting, Harvester requires its controller, validates every registered
vault's controller/asset/source/Harvester binding, and snapshots source-share
weights. Registry completeness is checked before distribution. Rates and
bindings live in the controller, not in extra per-vault policy storage.

Each controller policy change increments `configurationVersion`. Harvester
checks that version and the source shares after the whole batch, so a callback
changing policy, even changing it back, reverts the entire harvest. Harvester's
own registry/controller setters share its reentrancy guard. Each vault's wiring
is validated immediately before its compound call and again at completion.
Local guards also protect collection, claims,
and recipient changes. All swaps, accruals and supplies roll back on failure.

Direct `SubLoop.harvest()` still forwards PRIME to the configured Harvester.
The next distribution includes that parked balance and unsolicited PRIME.
Only the authenticated Harvester-funded compound path pays fees. Unregistered
or mismatched fee wiring cannot silently exempt a source-yield distribution.

## Fresh deployment

1. Deploy hook-enabled vault implementations/proxies, the SubLoop and the new
   Harvester. Configure reserves, roles, swapper, slippage and source/Harvester
   registries before accepting deposits. Existing deployment scaffolds are not
   a complete governance wiring transaction.
2. Run `script/DeployFees.s.sol:DeployFees` with `FEE_GOVERNANCE`,
   `FEE_RECIPIENT`, `HARVESTER`, and comma-separated `FEE_VAULTS`. It deploys a
   controller and prints governance calls, without executing those calls.
3. Governance executes the printed calls in order: Harvester controller, then
   each vault controller and controller registration. `SubLoop.harvester` must
   already point to that Harvester. Registration verifies that the source yield
   token matches Harvester's PRIME. Rehearse the complete batch on a fork.
4. Verify `validateVault`, each 500 bps rate, zero claim ledgers, treasury address,
   complete source-share registration and absence of unintended deployer roles.
5. Deploy/wire the borrowing discount separately using `DeployDiscount.s.sol`.
   Fees default to 500 bps; the borrowing discount still starts at zero.

The existing keeper still calls `harvest(uint256[])`; minimums are gross outputs
and its empty minimum array still uses the oracle floor. Claiming fees is a
separate permissionless transaction, not part of harvesting or user withdrawal.
Do not run keeper configuration against old contracts that lack these hooks.

## APY and rollout

For each vault, an annualized carry estimate is:

```text
netCarry = (1 - protocolFeeBps(vault)/10000) * realizedLoopCarryAfterSwapCosts
           - MainBorrowingInterest
```

Do not multiply net user APY by 95%: Main interest is outside the fee base.
UI integration must read the selected vault's rate and distinguish gross
harvest, fee and net compound. No fixed APY is promised.

Tests cover permissions, rate boundaries, collateral conservation, recipient
rotation, failed/reentrant transfers, different vault rates, gross slippage,
malicious swaps, parked yield, and policy changes during a multi-vault harvest.
Bytecode size must remain below EIP-170 with both fee and discount hooks.
Production deployment additionally requires independent review and resolution
of the existing queue, unwind, source-equity and keeper audit findings. This
feature does not claim to fix those unrelated launch blockers.

Run the full suite with `forge test --offline --evm-version london -vv`.
Optional pinned forks use `FEE_FORK_RPC` / `FEE_FORK_BLOCK` and
`DISCOUNT_FORK_RPC` / `DISCOUNT_FORK_BLOCK`; without an RPC their fixtures skip.
The fee fork exercises deployed Aave Pool/aToken supply code with controlled
underlying ERC20 balances, prices, swaps and source weights. The discount fork
exercises deployed HOLLAR debt accounting with controlled normalized indexes
and synthetic backing. Neither is a complete Substrate-token/DEX rehearsal.
The existing optional formal-parity harness is not a proof of the new fee code.
