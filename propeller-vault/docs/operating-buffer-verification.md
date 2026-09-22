# Operating Buffer Verification

Implementation branch: `feat/propeller-interest-buffer`, based on `propeller`
`55acd38229f2ccc949f00c474e641d6a0df551b2`. This is review evidence, not production
approval. See [the policy and ownership specification](operating-buffer.md).

## Findings That Matter

1. **Bootstrap ownership still needs a decision.** The current implementation
   treats allocated sponsorship as a depositor subsidy. Repeated entry/exit can
   claim that subsidy and exhaust the finite budget. There is no automatic
   treasury refill. A regression demonstrates this behavior. Before approval,
   explicitly accept it or make bootstrap repayable reserve capital; a user-owned
   buffer does not by itself answer who owns externally supplied startup capital.
2. **The pinned native market rejects even a small entry at a 1% floor.** A real
   runtime dry run sells 20.5 HOLLAR for 19.312911 PRIME. With Aave's $1.0505 PRIME
   price, the 1% floor requires 19.319371 PRIME. The native rehearsal records the
   rejection before using an explicit **fork-only 1.2%** setting. No production
   guard was weakened or oracle price overwritten to make deployment pass.
3. **Buffer coverage is finite and requires execution.** Eighteen of 370 scenarios
   lose the synthetic-only Main protection margin during keeper outages, totaling
   216 modeled vault-days. An idle cash balance cannot call `maintainPeg` or repay
   debt. No collateral liquidation occurred in these scenarios, but this is not
   proof of protection under an arbitrary outage or price collapse.
4. **Loss recovery remains real external funding.** Of the 370 cases, 250 require
   more than one cent of recovery funding, including modeled entry friction.
   Maximum recovery is 5.7111% of initial TVL. All public collateral principal is
   preserved after that funding; the implementation does not create the money.

## Contract Execution

Final ordinary regression run: **261 passed, zero failed, 11 skipped** across
38 suites using the normal runner gas limit. The skipped items are the eight
opt-in campaign methods plus optional fork/formal suites. The campaign separately
passes all eight methods / 370 scenarios, and the two pinned fork suites separately
pass all eight tests. Nine stateful invariants run 256 sequences of depth 50 each.
Keeper tests/build, native-rounding tests, standalone readiness typechecking and
Hardhat proposal task loading pass. Full proposal typechecking has the existing
market-config issue noted below.

`OperatingBufferCampaign.t.sol` runs actual vault, SubLoop, harvester, fee,
discount and operating-buffer contracts. The market boundary is explicit:
mocked Aave accrual, oracle paths, swap costs, source-liquidation effects and
unlimited trading capacity. These are **not 370 native forks** and do not prove
that current pools or facilitators can support $100m TVL.

- 180 main scenarios: six TVLs ($100k, $500k, $1m, $10m, $50m, $100m), 50/50
  ETH/tBTC, five 90-day paths (flat, bull, bear, seesaw, rally/crash), three Main
  discounts (0%, 50%, 100%), with/without a 30-day keeper outage.
- 190 sensitivities: harvest swap costs, loop route costs, 0/12-hour/14-day exit
  lags, three/seven-day harvests, 1/3/14/30-day buffers, gross exit reserves,
  and half exits on days 1/3/7 at $100k and $1m across all five paths.
- Fee basis remains 5% of fresh collateral after the PRIME swap, before Main
  servicing. Simulation coverage is seven days and gross exit allowance is
  10bp unless varied. The campaign's stress-rate floor is negligible so discount
  effects remain visible; native fixtures instead use a 5% floor. Neither is an
  approved production configuration.
- Deterministic starting prices are ETH $3,000 and tBTC $60,000, with a snapshot
  borrowing APR of approximately 4.4017%. PRIME income and rate stresses are
  specified fixtures, not a quote of current PRIME APY. Artifact template hashes
  in the summary bind the production contracts and declared mocks to this build.
- Assertions prohibit ordinary servicing from reducing collateral backing,
  require exact public deposited-token principal after recovery, conserve cash,
  and keep Main discounts out of SubLoop debt.
- 187 cases retain source claims above one cent after collateral settlement.
  They remain owned and claimable by the exits; they are not counted as cash paid
  and are not written off. Dedicated tests exercise later funding and claims.
- No liquidation was triggered by these 90-day paths. Separate `RecoveryE2E`
  tests model full PRIME-position loss, emergency freeze and staged governance
  recovery. They do not execute a native liquidation engine or implement the
  deferred fair recovery indexer.

The [CSV](evidence/operating-buffer-2026-09-22/contract-campaign.csv) contains all
370 unique executions, validated by the report generator. The
[summary](evidence/operating-buffer-2026-09-22/contract-campaign-summary.json)
contains aggregated funding, debt, return and residual-claim measures.

Illustrative $1m cases, no Main discount, keeper online:

| Path | Main interest | Bootstrap allocated | Recovery | Peak HOLLAR debt | ETH / tBTC token gain |
| --- | ---: | ---: | ---: | ---: | ---: |
| Flat | 7,302 | 5,442 | <0.01 | 4.79m | 1.83% / 1.95% |
| Bull | 9,499 | 8,704 | <0.01 | 7.14m | 1.78% / 1.89% |
| Bear | 15,174 | 5,442 | 37,177 | 4.68m | 0% / 0% |
| Seesaw | 9,326 | 7,003 | 7,599 | 5.92m | 0.27% / 0.28% |
| Rally/crash | 14,977 | 7,736 | 30,456 | 6.46m | 1.06% / 1.11% |

HOLLAR amounts assume the fixture's par valuation. Gains are realized collateral
token gains with half exits on day 60, **not annualized APY**. HOLLAR buffer payouts
are separate, can include sponsored capital, and are not investment income.

## Defects Found and Fixed

- Main down-rebalance completion originally subtracted principal serviced rather
  than total debt discharged. Accrued interest could leave the resize target
  stuck and block later exits. Resize and exit-principal accounting are now distinct.
- GHO discounts gross index growth. The reserve bound now discounts that growth
  rather than compounding an already-discounted rate.
- A native tBTC seed transaction exposed scaled-debt rounding: borrowed debt can
  be one wei below the requested HOLLAR amount. Reconstructing prior debt by
  subtraction underflowed. The buffer now snapshots and measures debt changes.
- Repayment measures cash spent separately from debt reduced. A bounded rounding
  retry uses the paying cohort's own HOLLAR; synthetic burning and collateral
  release follow debt discharged. Exact-arithmetic mocks now have rounding modes
  and regressions for initial borrowing, servicing and full exit.
- Keeper settlement includes late source claims after collateral settlement;
  buffer-read failures prevent new ramping without disabling safety repayments.
- The CommonJS proposal/readiness tooling now loads the shared pure rounding
  parser through an explicit `ts-node` module override.

## Native Scope

The rehearsal forks `hdx.tarn.hydration.cloud` at block **14900756**, runtime 443,
hash `0xc0f89ce05e34f0b024401fb220c0efc11c79b98a408b8e498281da4f744bae49`.
All transactions use localhost and public development keys. Governance calls are
local scheduler simulations, not enacted production governance.

The corrected vault is **24,399 bytes**, with **177 bytes EIP-170 headroom**.
Its constructor creates the immutable 4,974-byte helper. The buffer is 15,124
bytes; SubLoop is 19,766 bytes. Deployment does not raise native code-size or
transaction gas limits. Future changes must recheck these small margins.

**Final native lifecycle and artifact verification passed.** Two users deposited
in each of the ETH/tBTC vaults; real Aave interest accrued for one day before
harvest. Harvest cleared 0.052115775208400118 / 0.050533649741662950 HOLLAR of
Main interest, collected actual-collateral fees and grew collateral backing.
The rehearsal then exercised the withdrawal delay, a seven-day time advance,
source-wide emergency freeze, explicit recovery, unpause, real-route unwinding,
and collateral/HOLLAR claims for all four public positions.

All four collateral promises were paid exactly and exceeded deposited principal.
The gains include donated PRIME and source support: **they are not earned APY**.
After paying currently available exit cash, **59.846412587140330026 HOLLAR** for
the second ETH exit and **55.376485522087109087 HOLLAR** for the second tBTC exit
remain unpaid source claims, attributed to their original owner. Their Main debt
is zero. They were not written off or counted as paid; later recovery is covered
by focused contract tests, not a completed native recovery of those balances.

Live deployed bytecode was matched against final local artifacts (constructor
immutable fields checked separately), including the constructor-created helper
and proxy implementation slots. The vault implementation deployed using
10,874,958 gas, including helper creation; each buffer used 5,703,744 gas.
See [native evidence, receipts and log hashes](evidence/operating-buffer-2026-09-22/native-verification.json).

The final read-only readiness run passes **121/131 checks**, including all **16
operating-buffer checks**. It intentionally remains a failing production check:
eight governance/owner handover checks still see development accounts, and two
synthetic Substrate registry checks are missing. These are not waived.

The fork-only swap adapter is not a substitute for production HydraAugustus.
Bootstrap is 1,000 HOLLAR per vault; source support is 10 + 50 + 100 HOLLAR;
active-cohort recovery is 100 HOLLAR per vault. Donated PRIME is 100 tokens.
These are explicit external test funds, not automatic protocol resources.
The one-day accrual and later seven-day outage are distinct from the mocked
90-day campaign; large-TVL native liquidity and HSM execution remain unproven.

## Economic and Liquidity Reruns

The existing off-chain models were also rerun on the checked-in market snapshot:
720 policy cases plus 460 sensitivities; 108 pressure paths plus six entry sizes;
54 peg entry cases, 18 market paths and 13 sensitivities; two coupled 90-day $1m
cases with and without a funded buyer. All five model/calibration test files pass.
See [compact evidence and hashes](evidence/operating-buffer-2026-09-22/model-rerun-summary.json).

The corrected independent PRIME reference is 1.0606553548682192. Both coupled
cases have **zero entry fulfillment at the 1% floor**. Their quiet peg is therefore
not evidence that the proposed flow is absorbable. Snapshot HSM collateral is
about 285,099 and burn capacity about 283,273 HOLLAR; larger mint limits do not
fund redemption. The historical model alternatives remain controls, not additional
contract implementations. The full calibrated multi-TVL liquidity campaign with
committed replenishment/redemption capacity remains a production gate.

## Reproduction

With pinned `bil-vault/lib` dependencies, from `propeller-vault`:

```sh
forge test --offline --evm-version london -vv
RUN_OPERATING_CAMPAIGN=true FOUNDRY_GAS_LIMIT=1000000000000 \
  forge test --offline --evm-version london \
  --match-contract OperatingBufferCampaignTest --match-test test_campaign -vv
FEE_FORK_RPC=https://hdx.tarn.hydration.cloud FEE_FORK_BLOCK=14900756 \
DISCOUNT_FORK_RPC=https://hdx.tarn.hydration.cloud DISCOUNT_FORK_BLOCK=14900756 \
  forge test --offline --evm-version london \
  --match-contract 'ProtocolFeesForkTest|PropellerDiscountForkTest' -vv
```

The high runner gas limit allows dozens of independent 90-day executions inside
one Foundry test method. It is not a deployment limit change. Ordinary tests do
not run the optional 370-case campaign without its environment flag. Fork tests
use real Aave/GHO bytecode with controlled boundaries, not native DEX precompiles.

From the repository root, against a fresh local Chopsticks database using
`scripts/propeller/native-chopsticks.yml` (change port/database together when reused):

```sh
node scripts/propeller/native-deploy.mjs /tmp/propeller-native.json
node scripts/propeller/native-discount.mjs /tmp/propeller-native.json
PROPELLER_LOCAL_PORT=8142 node scripts/propeller/native-campaign.mjs /tmp/propeller-native.json
node scripts/propeller/native-verify.mjs /tmp/propeller-native.json
node scripts/propeller/report-operating-campaign.mjs /tmp/contract-campaign.log /tmp/contract-evidence
node scripts/propeller/report-native-verification.mjs /tmp/propeller-native.json \
  /tmp/readiness.log /tmp/regression.log /tmp/fork.log /tmp/native-verify.log /tmp/native-evidence.json
```

Scripts only address localhost and record changes/receipts. The final run uses a
fresh database on port 8143; set `PROPELLER_LOCAL_PORT=8143` for all four scripts
when checking that run. Native receipt history can be pruned, so every receipt
is checked when mined and bytecode/proxy bindings are verified again at the end.

## Remaining Gates

Resolve bootstrap ownership/incentives; approve and fund real buffer budgets;
resolve PRIME reference and route-floor compatibility; deploy the production
adapter; verify governance/committee handover and all custody exemptions; select
TVL/ramp limits from executable liquidity; fund emergency backstops; operate
redundant monitoring; and obtain independent review of the exact artifacts.
The existing formal bridge does not prove the new buffer implementation.

Standalone proposal typechecking still reports an existing duplicate `STHDX`
oracle key in `markets/hydration/index.ts:235`. This report does not silently
choose a production oracle address. Hardhat task loading and the standalone
readiness/keeper checks are separate from that repository configuration defect.

No Garden push, production deployment, merge or configuration approval is implied.
