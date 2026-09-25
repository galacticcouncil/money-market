# Main-vault HOLLAR borrow discount

## Scope and authority

`PropellerDiscount` combines a read-only eligibility adapter and GHO-compatible
discount-rate strategy. Install it as both discount references on the Main-market
HOLLAR variable debt token. It issues no token, holds no funds, and is not a proxy.
The HOLLAR debt-token implementation and storage are unchanged.

- Governance holds `DEFAULT_ADMIN_ROLE` and `RATE_ADMIN_ROLE`.
- The technical committee holds `RATE_ADMIN_ROLE`, not `DEFAULT_ADMIN_ROLE`.
- Both can call `setDiscountBps(0..10000)`. Zero disables the subsidy; a later
  nonzero value restores it. `8000` means 80% off interest, not an 80% borrow rate.
- Only governance can enroll/remove vaults and grant/revoke roles.
- Anyone can call `refreshAll()` or the debt token's existing
  `rebalanceUserDiscountPercent(address)`. Neither operation chooses the policy.
- The deployer receives no implicit authority. Configure the committee's actual
  execution address, not a member's wallet or the keeper key.

There is one rate across enrolled Main vaults. SubLoop is not eligible and keeps
paying the undiscounted HOLLAR rate. A rate does not guarantee an APY: PRIME yield,
base borrowing rate, utilization, trading costs and deployment progress vary.

## Eligibility

A borrower must satisfy ALL of:

1. It is in the governance-enrolled set (maximum 16 Main vaults).
2. It holds `MINTER_ROLE` on the configured synthetic token.
3. Its `discountController()` still points to this adapter.
4. It holds a positive balance of the configured synthetic aToken (`aPSYNTH`).

Registration checks the Main vault's pool, synthetic token, HOLLAR debt token,
and controller wiring. Governance must also verify the proxy implementation,
upgrade/admin authorities and approved yield source. Matching getters alone are
not a permissionless proof that a contract is a genuine vault.

`psHOLLAR` is minted by the vault and supplied to Aave; `aPSYNTH` is the receipt
left in the vault. Raw synthetic, ordinary HOLLAR, PRIME, or user-held vault
shares do not grant eligibility. The existing underlying and receipt tokens
remain transferable; a recipient cannot gain this discount without enrollment
and mint authority. Do not enroll EOAs, arbitrary minters or SubLoop.

Both synthetic and HOLLAR use 18-decimal $1 units. The rate returned at a refresh
is `discountBps * min(aPSYNTH balance, HOLLAR debt) / HOLLAR debt`, rounded down;
zero debt or backing gives zero. Normal buffered synthetic backing covers the
Main debt. Dust backing does not unlock a full-account discount. This is nominal
backing, not a liquidation-threshold or oracle-based eligibility test.

The explicit bounded set makes atomic repricing possible. It is not a second
tradeable badge token or a permission for the committee to enroll borrowers.

## Cache and lifecycle

GHO caches each borrower's discount. A rate change first changes policy and then
refreshes EVERY enrolled account, including those that lost mint authority or
detached their controller. The debt token settles prior interest using the OLD
cached percentage before calculating the new one. Any refresh failure reverts
the entire update. `unregisterVault` removes eligibility and clears the cache in
the same transaction, without revoking mint authority or blocking exits.
At a zero configured rate, the adapter returns zero without calling the vault,
synthetic or receipt token. A broken eligibility getter cannot prevent committee
shutdown; governance can then unregister the affected vault.

CollateralVault opts in through `setDiscountController(address)`. It refreshes
after synthetic supply (including first deposit, up-rebalance, and peg top-up)
and after settlement/withdrawal. First borrow occurs before the first synthetic
supply, so a post-supply refresh is necessary. Detaching the controller refreshes
the old policy to zero immediately. Zero controller preserves legacy behavior.

Mint-role revocations, exceptional receipt movements and other external policy
changes do not automatically checkpoint the debt token. Governance must batch
them with `refreshAll()` or the affected account's debt-token refresh. Do not
revoke `MINTER_ROLE` merely to stop a subsidy; that also disables peg maintenance.
Before upgrading a vault or changing its approved purpose, detach/revoke its
discount, validate the replacement, then re-enable through governance.

This uses native GHO accounting: discounts are cached between actions. Backing
proportions are not a continuously enforced debt ceiling. There is no hard
annual subsidy budget or new borrowing cap in this change. Existing Propeller
and money-market limits still apply. Operational monitoring should track actual
debt and foregone interest, not assume a fixed expense from the percentage alone.

## Fresh Deployment

1. Verify the deployed Main HOLLAR debt-token implementation, existing discount
   policy/cache, pool-admin authority, synthetic reserve and aToken addresses.
   Do not replace an unrelated active discount program with this one implicitly.
2. Use the current fresh-deployment vaults with the refresh hooks. No migration
   from an older Propeller layout is supplied. Earlier PR #53 layout findings
   are historical review context, not an upgrade-compatibility approval for RC1.
   See the [current source upgrade boundary](source-upgrades.md).
3. Deploy `PropellerDiscount` at its default zero rate. `DeployDiscount.s.sol`
   reads `HOLLAR_VDEBT`, `SYNTH`, `ASYNTH`, `DISCOUNT_GOVERNANCE`,
   `DISCOUNT_COMMITTEE`, comma-separated `DISCOUNT_VAULTS`, and optional
   `DISCOUNT_BPS` (default zero). It prints target/calldata pairs for installation;
   it never executes those governance calls. A Forge simulation without
   `--broadcast` does not deploy anything to the network.
4. Execute installation as an atomic governance batch: set both HOLLAR discount
   references; set each Main vault's controller; register each vault; set the
   explicitly approved percentage. Include existing mint/loop/harvester wiring
   for newly created vaults. Never register the shared SubLoop.
5. Assert the complete participant list, cached percentages, committee rate
   authority and absence of deployer admin authority. Estimate the full-list
   refresh on the target runtime before enactment, including newly accrued debt.
6. To replace a controller later, first set its rate to zero and checkpoint all
   participants. Then install/wire/enroll the replacement in the governance
   batch. Replacing the strategy reference alone leaves old cached discounts.

Committee operation after installation: `setDiscountBps(8000)` on the controller
sets an 80% interest discount on every eligible Main vault and refreshes all of
them atomically. This example is not a deployment approval or fixed APY promise.

## Tests

```sh
forge test --match-contract 'PropellerDiscountTest|CollateralVaultDiscountTest' -vv
DISCOUNT_FORK_RPC=https://hdx.tarn.hydration.cloud forge test --evm-version london --match-contract PropellerDiscountForkTest -vv
```

Set `DISCOUNT_FORK_BLOCK` to pin a fork. Without `DISCOUNT_FORK_RPC`, fork tests
are explicitly skipped. London mode accommodates Hydration RPC headers without
`prevrandao`. Unit tests cover authority, enrollment, zero/dust backing,
rate bounds, cache refresh, atomic rollback, first/incremental deposits, up-rebalance,
peg maintenance, settlement and exits after revocation. Fork tests use the deployed
HOLLAR debt token, controlling only its normalized debt index and synthetic backing,
to check historical-interest preservation, future repricing, full waiver and repay.
They are not end-to-end tests of the Substrate-backed collateral/router paths.

The UI must read `getDiscountPercent(vault)` separately from the SubLoop rate:

```text
annual net carry = mainLtv * (loopLeverage * primeYield
                   - (loopLeverage - 1) * subLoopBorrowRate - mainBorrowRate)
mainBorrowRate = reserveBorrowRate * (1 - cachedDiscountBps / 10000)
```

This is an annualized carry approximation, not exact compounded APY. A display
that subtracts one common borrowing rate from PRIME yield will miss this Main-only
discount; frontend integration is separate from the contract implementation.
