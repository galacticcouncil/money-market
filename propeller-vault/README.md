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
| [CollateralVault](src/CollateralVault.sol)               | One vault per collateral asset; shares, Main position, delayed withdrawals and collateral claims.         |
| [SyntheticToken](src/SyntheticToken.sol)                 | Non-cash collateral used to maintain the Main health-factor floor. It cannot fund repayments.             |
| [SubLoop](src/SubLoop.sol)                               | Shared PRIME exposure, HOLLAR borrowing, incremental deployment/unwinding and retained execution yield.   |
| [Harvester](src/Harvester.sol)                           | Splits harvestable PRIME among participating vaults; each vault compounds its allocation.                 |
| [PropellerMainDebt](src/PropellerMainDebt.sol)           | Per-vault ledger separating active-holder and started-exit debt, cash, source claims and late recoveries. |
| [PropellerFeeController](src/PropellerFeeController.sol) | Per-vault harvest fees held in underlying collateral for the configured recipient.                        |
| [PropellerDiscount](src/PropellerDiscount.sol)           | Main-only HOLLAR interest discount for governance-enrolled vaults.                                        |

There are two distinct debts: **Main debt** belongs to each collateral vault;
**loop debt** belongs to the shared PRIME strategy. Repaying one does not
automatically repay the other. The PRIME loop can suffer losses or liquidation.
Synthetic collateral protects Main's health factor under its stated assumptions,
but does not replace missing HOLLAR.

## User Lifecycle

1. **Deposit.** Supply collateral to Main, borrow HOLLAR within the live reserve
   LTV, supply synthetic backing and acquire shares in the PRIME source.
   Governance funds the locked bootstrap shares and rounding reserve first.
   Deposits reject insufficient backing; admission-size controls remain an
   activation gate.
2. **Earn.** Source surplus first retains an earned PRIME allowance for execution
   costs. A harvest swaps the remaining allocation into each vault's collateral,
   charges its fee, services Main interest and compounds the remainder.
   No minimum yield or fixed APY is promised.
3. **Rebalance.** Collateral appreciation can permit more Main borrowing.
   Falling collateral value triggers a PRIME-loop unwind whose net HOLLAR
   repays Main. Ordinary resizing does not sell deposited collateral.
4. **Request withdrawal.** `requestRedeem` escrows shares for the configured
   delay, initially 12 hours. Those shares remain invested during the wait.
   Governance can set `setWithdrawalDelay(uint32)` to zero for future requests;
   queued requests keep their original eligibility time.
5. **Unwind and settle.** After eligibility, permissionless `startUnwinds`
   processes strict FIFO and stops at the first ineligible request. It snapshots the
   collateral entitlement and debt allocation. `pokeRepay` frees source HOLLAR;
   `pokeSettle` services debt and releases collateral. Exits bear their own
   post-start interest. A shortfall preserves the unpaid claim.
6. **Claim.** The owner claims settled collateral, including partial payments.
   A completed exit's later source surplus remains payable in HOLLAR to its
   original owner through the Main debt ledger. Twelve hours is the earliest
   unwind start, not a payout deadline.

Ordinary settlement is FIFO. During an incident, freeze affected withdrawals
before preparing fair recovery for **all affected holders**, including holders
without withdrawal requests. Automatic all-holder settlement and extraction of
compounded user yield are not implemented. See [principal and emergency policy](docs/principal-safety.md).

## Controls and Defaults

| Control                | Authority and RC behavior                                                                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Main interest discount | Governance and Technical Committee set one rate across eligible Main vaults; deployment defaults to zero until approved. Loop debt is not discounted. |
| Protocol fee           | Governance sets a rate per vault, initially 5% of harvested collateral after swaps and before Main interest.                                          |
| Treasury recipient     | Owner-configurable; all unclaimed fees follow the new recipient. Anyone may trigger payment to that recipient.                                        |
| Withdrawal delay       | Governance-configurable per vault, initially 12 hours before unwinding; existing requests retain their eligibility time.                              |
| Emergency freeze       | Guardian can freeze; governance reopens. Local vault freeze and source-wide emergency freeze are distinct from the source route kill switch.          |
| Swap limits            | Oracle-relative floors are enforced on-chain; no automatic widening. Production floors, tranches and TVL/ramp budgets still require approval.         |

The earned execution allowance, donated collateral rounding reserve and treasury
fees are different balances. There is **no mandatory sponsored HOLLAR operating
buffer**. [Main servicing](docs/main-debt-servicing.md) explains their funding
and the fee/interest/compounding order.

## Verification and Limits

- Ordinary Solidity regression: **287 passed, zero failed, 11 optional tests or
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
production migration from the superseded operating-buffer design is supplied.
The current feature branch is `feat/propeller-interest-buffer`; its name is historical.

Future source rotation should preserve the source proxy, storage and claim
ownership. Compatibility tests and a [deferred rotation plan](docs/source-upgrades.md)
exist; concurrent old/new strategy operation is not implemented.
