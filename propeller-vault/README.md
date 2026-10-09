# Propeller

**RC1 for team review | 23 September 2026 | Production activation blocked**

Propeller deposits user collateral into Hydration's Aave money market, borrows
HOLLAR against it, and deploys that HOLLAR into a shared leveraged PRIME strategy.
Eligible yield is converted back into the user's deposited asset.

The policy is to preserve original deposited-token principal. This is not a USD
value guarantee or an unconditional contract guarantee: losses can delay exits
until governance funds recovery. Main protection depends on valid configuration,
oracle inputs and timely synthetic-collateral maintenance.

Start with the [team documentation index](docs/README.md) and
[RC scope, evidence and activation gates](docs/release-candidate.md).

This README describes the next version on `juicer-next`
([plan](docs/next-version-plan.md)): the keepers check underfunding off-chain
and stop deposits themselves, yield is allocated at events instead of on every
transfer, and funded earnings are part of each holder's vault balance, so
nothing is claimed. ICE intents are replacing the router for entries, harvest
swaps and normal exits, which become asynchronous; the synchronous router stays
for the safety de-lever. That work (track B) is still being integrated, and
these documents describe the router flow until it lands.

## Architecture

```text
User collateral (ETH or tBTC)
  |
  v
CollateralVault -> Aave Main position
  |                 collateral + synthetic floor; HOLLAR debt
  |
  +-> borrowed HOLLAR -> shared SubLoop -> leveraged PRIME in Aave
                                            |
                                  harvestable PRIME surplus
                                            |
                                        Harvester
                                            |
                   per-vault swap into the deposited collateral
                                            |
                     protocol fee -> Main interest -> compounding
```

| Component                                                | Responsibility                                                                                            |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| [CollateralVault](src/CollateralVault.sol)               | One vault per collateral asset; funded shares, gradual Main deployment, delayed withdrawals and collateral claims. |
| [ExecutionController](src/ExecutionController.sol)       | Shared swap sizes, pacing, volume budgets, fresh quotes and total MM-oracle cost limits. |
| [SyntheticToken](src/SyntheticToken.sol)                 | Non-cash collateral used to maintain the Main health-factor floor. It cannot fund repayments.             |
| [SubLoop](src/SubLoop.sol)                               | Shared PRIME exposure, HOLLAR borrowing, incremental deployment/unwinding and retained execution yield.   |
| [Harvester](src/Harvester.sol)                           | Splits harvestable PRIME among participating vaults; each vault compounds its allocation.                 |
| [PropellerYieldAccounting](src/PropellerYieldAccounting.sol) | Reward units allocated at equity events, each holder's funded slice of the reward fund, and realization accounting. |
| [PropellerMainDebt](src/PropellerMainDebt.sol)           | Per-vault ledger separating active-holder and started-exit debt, cash, source claims and late recoveries. |
| [PropellerFeeController](src/PropellerFeeController.sol) | Per-vault harvest fees held in underlying collateral for the configured recipient.                        |
| [PropellerDiscount](src/PropellerDiscount.sol)           | Main-only HOLLAR interest discount for governance-enrolled vaults.                                        |

There are two distinct debts: **Main debt** belongs to each collateral vault;
**loop debt** belongs to the shared PRIME strategy. Repaying one does not
automatically repay the other. The PRIME loop can suffer losses or liquidation.
Synthetic collateral protects Main's health factor under its stated assumptions,
but does not replace missing HOLLAR.

## User Lifecycle

1. **Deposit.** Supply collateral to Main and receive funded vault shares.
   Deposits do not borrow HOLLAR or swap. Keeper rebalances deploy pooled
   collateral in quoted slices, borrowing only the immediately executable amount
   within the live reserve LTV and supplying synthetic backing atomically.
   Governance funds the locked bootstrap shares and rounding reserve first.
   Deposits revert while governance's `depositsPaused` or the keepers'
   `deficitStop` is set, or while a Main resize or source allocation is
   pending; backing itself is checked off-chain by the keepers. Waiting collateral creates no new debt;
   production trade sizes, pacing and price bounds remain activation settings.
2. **Earn.** Source surplus first retains an earned PRIME allowance for execution
   costs. A harvest swaps the remaining allocation into each vault's collateral,
   charges its fee, services Main interest and compounds the remainder.
   No minimum yield or fixed APY is promised.
   Anyone can trigger the Harvester; only that contract can pull source yield,
   so the pull and distribution are atomic. [Separate yield ownership](docs/yield-ownership.md)
   keeps prior earnings with their owners. Yield is allocated at deposits,
   redemption requests, unwind starts, rebalances and the permissionless
   `sync()`, which keepers call after price updates; transfers only settle their
   two holders. Funded rewards are part of each holder's vault balance and keep
   compounding; nobody claims.
3. **Rebalance.** Pending deposits and newly earned collateral permit Main borrowing
   without waiting for the price-movement band. Collateral appreciation can
   also permit more borrowing.
   Falling collateral value triggers a PRIME-loop unwind whose net HOLLAR
   repays Main. Ordinary resizing does not sell deposited collateral.
4. **Request withdrawal.** `requestRedeem` escrows shares for the configured
   delay, initially 12 hours. Those shares remain invested during the wait.
   Governance can set `setWithdrawalDelay(uint32)` to zero for future requests;
   queued requests keep their original eligibility time.
   A request beyond the wallet commits reward units to it;
   `requestRedeem(type(uint256).max, owner)` is a full exit.
5. **Unwind and settle.** After eligibility, permissionless `startUnwinds`
   processes strict FIFO and stops at the first ineligible request. It folds the
   exit's funded earnings into the escrow, then snapshots the
   collateral entitlement and debt allocation. `pokeRepay` frees source HOLLAR;
   `pokeSettle` services debt and releases collateral. Exits bear their own
   post-start interest. A shortfall preserves the unpaid claim.
6. **Claim.** Settled collateral, including partial payments, is paid to the
   owner. Anyone may deliver it (the keeper does); only the owner may choose
   another receiver. A completed exit's later source surplus remains payable in
   HOLLAR to its original owner through the Main debt ledger, again by anyone. Twelve hours is the earliest
   unwind start, not a payout deadline.

Ordinary settlement is FIFO. During an incident, freeze affected withdrawals
before preparing fair recovery for **all affected holders**, including holders
without withdrawal requests. Automatic all-holder settlement and extraction of
compounded user yield are not implemented. See [principal and emergency policy](docs/principal-safety.md).

## Controls and Defaults

| Control                | Authority and RC behavior                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Main interest discount | Governance and Technical Committee set one rate across eligible Main vaults; deployment defaults to zero until approved. Loop debt is not discounted. |
| Protocol fee           | Governance sets a rate per vault, initially 5%. Yield ownership and its fee vest at checkpoint; collection waits for realization.                                          |
| Treasury recipient     | Owner-configurable; all unclaimed fees follow the new recipient. Anyone may trigger payment to that recipient.                                        |
| Withdrawal delay       | Governance-configurable per vault, initially 12 hours before unwinding; existing requests retain their eligibility time.                              |
| Emergency freeze       | Guardian can freeze; governance reopens. Local vault freeze and source-wide emergency freeze are distinct from the source route kill switch.          |
| Share transfers        | Stopped only by a vault's own pause, not by a source-wide freeze. A vault's `pause()` reverts while that freeze is set, so pause vaults first.        |
| Deposit stops          | Guardian `pauseDeposits`, and the keepers' `deficitStop` (`DEPOSIT_GUARDIAN_ROLE`): set above a 50 bps off-chain deficit, cleared below 25 bps.       |
| Protocol reserve       | Governance funds HOLLAR per Main ledger (`fundReserve`); drawn only for realized exit shortfalls, never counted as backing. Admin can withdraw.       |
| Swap limits            | Oracle-relative floors are enforced on-chain; no automatic widening. Production floors, tranches and TVL/ramp budgets still require approval.         |

The earned execution allowance, donated collateral rounding reserve, protocol
reserve and treasury fees are different balances. There is **no mandatory
sponsored HOLLAR operating buffer**. [Main servicing](docs/main-debt-servicing.md)
explains their funding and the fee/interest/compounding order.

## Verification and Limits

- The next version's changes carry per-change Forge and keeper tests (see the
  [plan](docs/next-version-plan.md)); its verification record (plan step 7) is
  not written yet. The counts below are for earlier revisions.
- The [4 October deferred-deployment report](docs/deferred-deployment-validation-2026-10-04.md)
  records 367 passing contract tests, 48 keeper tests, current artifact sizes,
  native deposit/withdrawal receipts and the remaining execution/activation gates.
- The [#62 implementation record](docs/pr62-completion-2026-10-02.md) covers
  separate yield ownership, claimable earnings and prompt reinvestment. Use its
  final regression and artifact sizes for the current ownership revision.
- The [2 October #60/#61/#63 integration](docs/pr-integration-2026-10-02.md)
  passed **297 Solidity tests**, with zero failures and 11 optional skips, plus
  19 keeper tests and its build. That earlier CollateralVault had 138 bytes of runtime headroom.
- September Solidity regression: **287 passed, zero failed, 11 optional tests or
  setups skipped**. Detailed scope and logs are in the [RC record](docs/release-candidate.md).
- Native HydraAugustus lifecycle and Main resizing passed on an `hdx.tarn`
  fork with an explicitly changed oracle-reference fixture and recovery funding.
  Unchanged-market entry did not pass the strict floor.
- The 90-day actual-contract campaigns cover six TVLs from $100k to $100m,
  five market paths, Main discounts and keeper outages. Aave/router market
  behavior is mocked; full principal assertions rely on explicit recovery where
  needed. They are not a $100m native-liquidity demonstration.
- Existing [formal work](formal/README.md) has bounded scope and assumptions;
  it does not prove the revised Main debt ledger or execution-cost accounting.
  Its next-version models (balances, event allocation, exit fold, ICE in
  flight) follow the plan; bridge parity with the Solidity is still to run.

The current release gates are maintained in one place:
[RC1 activation gates](docs/release-candidate.md#activation-gates).
Historical audits, deployments and model reports are supporting evidence,
not approval of this candidate.

## Build and Test

From the repository root, initialize the pinned dependencies:

```sh
git submodule update --init bil-vault/lib/forge-std bil-vault/lib/openzeppelin-contracts bil-vault/lib/openzeppelin-contracts-upgradeable bil-vault/lib/solmate
```

From `propeller-vault`, run Forge jobs serially against the shared build output:

```sh
forge build --offline --evm-version london
forge test --offline --evm-version london
```

Optional fork suites require their explicit RPC variables; a plain test run is
not native route coverage. See [verification commands](docs/main-debt-verification.md#reproduce),
[route evidence](docs/route-execution-calibration.md) and the
[keeper runbook](looper/README.md).

## Deployment and Upgrades

Use the [deployment runbook](DEPLOYMENT.md) for fresh deployments only. No
production migration from funded older accounting is supplied. The ownership
revision is reviewed in `prop_carry`, stacked on #60/#61/#63; the next version
is on `juicer-next`, stacked on `prop_carry`, and is a fresh deployment too. The
older `feat/propeller-interest-buffer` branch name is historical.

Future source rotation should preserve the source proxy, storage and claim
ownership. Compatibility tests and a [deferred rotation plan](docs/source-upgrades.md)
exist; concurrent old/new strategy operation is not implemented.
