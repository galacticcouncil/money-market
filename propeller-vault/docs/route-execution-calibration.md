# Production Adapter and Execution Calibration

Verification checkpoint, 2026-09-23, included in [RC1](release-candidate.md).
This is not a production deployment, oracle-price approval, slippage approval
or independent audit. No production Solidity was changed for this investigation.
The RC designation does not close the production gates identified here;
see also the subsequent [pricing and replenishment validation](prime-pricing-replenishment.md).

## Decision

**Keep production entry closed.** On the pinned market, reducing the order size
does not make the existing 100 bp oracle-relative entry floor executable.
Do not widen that floor automatically or replace the oracle with a pool quote.

The HydraAugustus implementation can execute the required sell routes. Remaining
price/reference and inventory prerequisites must be resolved separately from
adapter compatibility. A conditional oracle-update rehearsal is not evidence
that the unchanged production market supports the lifecycle.

## Pinned Inputs

- Hydration `hdx.tarn`, finalized block **14,937,805**, runtime **443**.
- Block hash `0xfa8eb3c9631c556b63ba14391d22eb228a3e288ee805fbaa91ce005103d2458f`.
- Local RPC `127.0.0.1:8145`, public development keys only. Chain writes are
  confined to Chopsticks. No code-size, runtime, or per-transaction gas limit
  was raised. Wallet funding and governance injections are explicit fixtures.
- [HydraAugustus source](https://github.com/galacticcouncil/aave-debt-swap/blob/ddc883efe18ddb6bb90a40d370f3280f51bda0d8/src/contracts/hydra/HydraAugustus.sol),
  commit `ddc883efe18ddb6bb90a40d370f3280f51bda0d8` from
  `ys-debt-collateral-swap`. Compiled with Solc 0.8.22, optimizer 200, London.
- The independent Solana reference was collected at slot **449,650,994**:
  **1.060805520790896 wYLDS per PRIME**, fresh when collected. This is not an
  executable USD redemption quote or a committed replenishment service.

## Pricing Diagnosis

The Aave oracle and pool-143 peg both report **$1.0505 per PRIME**. The oracle is
the governance-managed `0xDEe587cC569bf1FcBdcD6d1472031d225f34C307`, last updated
on **2026-07-31 02:00:06 UTC**, about **54.27 days** before the pinned block.
The pool holds **318,702.236297 PRIME** and **735,874.483524 HOLLAR**.

Native quotes and the official SDK pool math agree exactly on 35 checked quotes,
including both folded Aave routes. There is no observed decimal-conversion or
SCALE-encoding mismatch explaining the rejection.

| HOLLAR input | PRIME received | Loss relative to current oracle |
| -----------: | -------------: | ------------------------------: |
|            1 |       0.942099 |                       103.25 bp |
|          100 |      94.209523 |                       103.29 bp |
|        1,000 |     942.060808 |                       103.65 bp |
|        5,000 |   4,709.529500 |                       105.28 bp |

The inverse marginal market price is close to the independent reference, which
is about 0.98% above the manual oracle. This supports a stale-reference
explanation, but converting wYLDS into USD still needs authoritative validation.
Pool imbalance and fees are the immediate causes of the on-chain minimum-output
failure relative to the currently configured oracle.

Updating only the oracle is not a complete fix: pool 143 follows the same source.
Once its peg catches up, the unchanged inventory again quotes outside the 1%
entry floor. Neither a transient passing quote nor historical arbitrage proves
that inventory will be replenished on time.

## Adapter Coverage

The native harness now accepts the actual external HydraAugustus artifact,
configures its asset-ID map, deploys it normally, and verifies its runtime
against the compiled artifact, excluding only constructor immutable slots.
The candidate runtime is **4,919 bytes**, deployment gas **1,883,802**.

Successful submitted swaps cover PRIME to ETH, PRIME to tBTC, ETH to HOLLAR,
tBTC to HOLLAR, and PRIME to HOLLAR. Each retained the 100 bp oracle-relative
floor. Above-quote minimums revert; successful swaps leave no input/output
token balances in the adapter. HOLLAR to PRIME remains rejected at the floor.
Diagnostic zero-minimum quotes are simulations only, never submitted swaps.

The adapter retains allowances to the dispatch precompile. This is recorded,
not described as allowance cleanup. Propeller calls only `sell`; HydraAugustus
`buy` reverses the two amount parameters relative to `ISwapper.buy` despite
sharing its selector. It must not be used through that interface without an
explicit compatibility change. The existing 19 swap tests and seven owner/map
tests pass; those tests are not a security audit of arbitrary dispatch data.

Three largest PRIME-input adapter probes lacked enough liquid PRIME in the
diagnostic wallet after its Aave supply. Their `TRANSFER_FROM_FAILED` results
are fixture-funding failures, not pool-capacity measurements. Quotes through
$2,500 and the direct $5,000 folded loop quotes are available.

## Conditional Execution

The original-market entry rejection is preserved separately. A second run
rehearses governance updating the manual oracle to **1.06080552**, explicitly
assuming wYLDS equals $1. Its original pool inventory is not overwritten and
the **100 bp floor remains unchanged**. This is a conditional configuration
test, not a proposed or approved production oracle value.

The harness exercises both vaults and four public positions, actual Aave debt
accrual, harvest-time Main servicing, collateral-denominated fee claims,
withdrawal delay, emergency pause, recovery and exact collateral payouts.
It uses a donated 100 PRIME harvest fixture and separately recorded external
HOLLAR recovery. Its token gains are not organic yield or APY evidence.
**The conditional lifecycle passed.** All four users received their exact
promised collateral, at least their deposited token amounts. After governance
bridged Main repayment, outstanding source claims remained owned by those users.
The follow-up drained those claims through normal source/settlement calls and
paid all four original owners their remaining HOLLAR; final claims are zero.

A separate resize rehearsal reduces the remaining ETH seed position's reserve
LTV by 1,500 bp through fork governance, then restores it. This exercises a
lower Main target without pretending that real AMM prices crashed. It records
pre-existing recovery cash and checks Main debt/PRIME reduction without consuming
collateral. **It passed:** Main debt decreased from **20.58590044 to
18.41754634 HOLLAR**, source aPRIME from **82.206062 to 63.961105**, and the
remaining aETH collateral did not decrease. The original 75% LTV was restored
after testing 60%. It is distinct from the completed four-user withdrawal
lifecycle; pre-existing recovery cash was not treated as newly earned yield.

## Tranche Candidates

No newly calibrated production setting is approved or installed. A local
candidate is **1,000 HOLLAR per keeper borrowing call** and **900 PRIME per
unwind call**, with the original 100 bp floor retained for the native rehearsal.
The existing lifecycle uses the smaller 100 PRIME unwind tranche; the resize
rehearsal checks the candidate configuration separately.

After validating the reference and replenishment, **25 bp and 50 bp** are
candidate loop ceilings for further review. Current-state entry capacity is
zero at both, and at 100 bp. A 10 bp ceiling has too little demonstrated margin
to recommend for launch. Main collateral-servicing routes should not inherit
the tight loop ceiling: the tBTC-to-HOLLAR quote loses about **81.43 bp at $1,000**
and **105.45 bp at $2,500**, even in this single snapshot. ETH-to-HOLLAR loses
about **49.44 bp at $1,000**. Quotes must be refreshed before execution.

Conditional SDK sizing after both oracle and pool peg update:

| Additional PRIME sold by an external trader | 1,000 HOLLAR entry loss | Maximum single entry at 25 bp |       At 50 bp |
| ------------------------------------------: | ----------------------: | ----------------------------: | -------------: |
|                                           0 |               101.84 bp |                             0 |              0 |
|                                      50,000 |                66.49 bp |                             0 |              0 |
|                                     100,000 |                40.35 bp |                             0 |  42,722 HOLLAR |
|                                     150,000 |                18.86 bp |                 32,607 HOLLAR | 142,351 HOLLAR |

These are average-fill bounds in isolated hypothetical inventories, not daily
capacity, terminal-price limits, proven arbitrage profitability or pledged
funding. The trader receives existing pool HOLLAR; no reserves appear for free.

Two contract constraints prevent treating tranche configuration as complete
admission/throughput control:

1. `deployTranche` caps `pokeBorrow`, but `deposit` and upwards Main resizing
   call `_fundDeploy` with the whole amount. Large deposits must fail at their
   floor or be bounded/queued by an additional admission design.
2. Harvest distributes the whole available surplus. Long harvest gaps or large
   TVL can produce a route-sized failure; lowering borrowing tranches does not
   split that harvest. Bounded harvest execution is a separate implementation
   prerequisite for scaling beyond demonstrated route sizes.

At one 1,000-HOLLAR keeper call every five minutes, idealized keeper borrowing
alone takes approximately **1.4 / 7.0 / 13.9 / 139 / 696 / 1,393 days** for
$100k / $500k / $1m / $10m / $50m / $100m TVL. This assumes initial Main deposits
already executed and continuous liquidity; real HF convergence, outages and
refill delays only add time. It is a cadence example, not the keeper's asserted
production configuration.

## Retention Campaign

The actual-contract campaign compares 25/50/100 bp ceilings at two symmetric
loop-cost assumptions, 10 and 25 bp. A conservative 85 bp collateral-swap cost
is used in the main grids, covering measured small servicing-route costs.
These are conditional cost scenarios, not a claim that today permits entry,
or that future fills are symmetric, constant, or always available.

Each of six runs covers the complete six-TVL, 50/50 ETH-tBTC, 90-day grid: flat,
bull, bear, seesaw and rally/crash; 0/50/100% Main discounts; with/without a
30-day keeper outage, plus 190 sensitivities. The market boundary is mocked;
the vault/source/ledger/fees/discounts/settlement are real Solidity code.
Full target exposure uses the campaign's large mock-market tranches. Its returns
must not be presented as achievable at native liquidity or the candidate keeper
cadence above.

At $1m target TVL, the initial gross loop is about $4.787m. Full-position cost
holdback targets are approximately **$11,967 / $23,934 / $47,868** for
25/50/100 bp ceilings. These are yield-retention targets, not insurance funds
or required prefunding. An unfilled target can suppress both compounding and
harvest-time Main servicing.

The higher-cost runs exposed exits still awaiting source cash after the 1,500
settlement-call budget. The test recovery process now separately measures the
HOLLAR needed to bridge those remaining Main balances. It preserves the original
source receivables and exact deposited-token principal assertions. This is
additional explicit governance funding in a test, not a production accounting
change or a silent relaxation of a failing assertion.

### Results

**2,220 scenario executions passed:** six runs of 370 cases. Sensitivity rows
repeat across runs, so these are not 2,220 unique parameter combinations.
Every run settled deposited-token principal after its explicitly measured
governance funding. All cases needed some external support, including initial
entry friction; this is not evidence of a self-funding principal guarantee.

Illustrative $1m TVL, flat market, no keeper outage, no Main discount:

| Loop cost | Retention ceiling | ETH token gain | tBTC token gain | External HOLLAR support | Paid HOLLAR surplus | Still-owned source claim |
| --------: | ----------------: | -------------: | --------------: | ----------------------: | ------------------: | -----------------------: |
|     10 bp |             25 bp |          0.27% |           0.29% |                  375.00 |            3,034.20 |                 3,717.93 |
|     10 bp |             50 bp |             0% |              0% |                  375.00 |            3,772.66 |                 7,788.79 |
|     10 bp |            100 bp |             0% |              0% |                  375.00 |            3,779.51 |                 8,519.33 |
|     25 bp |             25 bp |             0% |              0% |                4,802.30 |               <0.01 |                     0.30 |
|     25 bp |             50 bp |             0% |              0% |                3,784.81 |                5.84 |                   815.49 |
|     25 bp |            100 bp |             0% |              0% |                3,784.81 |                5.84 |                   815.49 |

Token gains include partial and final exits over 90 days, **not annualized
APY**. HOLLAR surplus is separate from compounded collateral; an unpaid source
claim is not cash. Returns also depend on the explicitly funded recovery.
The native follow-up collected all four users' late claims, but the 90-day
campaign can end with preserved receivables as shown here.

Across all paths/sensitivities, peak gross external support was **7.06% of TVL**
in the lower-cost runs and **8.43%** in the higher-cost runs. The newly measured
end-of-test liquidity bridge was at most **0.00011034% of TVL**, approximately
$1.10 per $1m; it is included in total support, not added twice. Larger amounts
above include entry friction and source/debt shortfalls, not just that bridge.

No modeled loop liquidation occurred. Each run nevertheless recorded 216
pre-maintenance synthetic-collateral floor misses. This is not a guarantee of
safety under arbitrary keeper outages or live market/liquidation mechanics.

**Calibration conclusion:** do not select a production ceiling from the return
table alone. At low costs a 25 bp holdback enables earlier compounding, while at
higher costs that extra turnover can increase the need for recovery. First
resolve the reference/inventory gate, then bound actual trade sizes and select
a ceiling supported by executable two-way quotes and a funded loss budget.

## Verification and Evidence

[Evidence summary](evidence/route-execution-2026-09-23/summary.json) links the
pinned market, baseline rejection, conditional lifecycle, resize, calibration,
all six CSV campaigns and their raw Forge logs. Ordinary regression:
**279 passed, zero failed, three optional setups skipped**. Adapter tests:
**19 swap plus seven configuration tests passed**. Calibration tests:
**eight passed**, including 35 exact native/SDK quote matches.

Final bytecode, proxy bindings, fee policy, discount registration and exit
ownership/accounting checks passed on the fork. All seven production runtime
templates match the prior Main-debt checkpoint. `CollateralVault` remains
24,381 bytes, just **195 bytes below EIP-170**; no additional production code
was squeezed into that budget during this task.

The evidence generator rejects incomplete verification, failed/missing campaign
rows, stale outstanding native exit claims or changed production templates.
Raw logs and hashes are retained locally. These files are not a deployment
manifest or authorization to change production settings.

## Reproduce

Run from the repository root with its installed dependencies, Solc 0.8.22 and
the pinned Hydration SDK math. Start a fresh, isolated Chopsticks database using
`scripts/propeller/route-chopsticks.yml`; its upstream is `hdx.tarn`. Build the
external adapter at the exact commit/compiler/remappings above and retain its
artifact separately: rebuilding with different remappings changes metadata.
The native order is `native-deploy.mjs`, `native-discount.mjs`, then
`native-campaign.mjs`, all using `PROPELLER_LOCAL_PORT=8145` and the same result
file. Set `PROPELLER_ADAPTER_ARTIFACT` to the pinned HydraAugustus artifact and
`PROPELLER_PROBE_ROUTES=true` for the campaign. Verify the blocked baseline with
`native-verify.mjs` and preserve it before continuing a separate result file with
`PROPELLER_TEST_REFERENCE_FILE` set to the collected reference. Run
`native-resize.mjs` only after that conditional lifecycle passes, then rerun
`native-verify.mjs` against its final state. Never enable the legacy relaxed-floor
fixture for this evidence.

Offline evidence/calibration replay (SDK math location is installation-specific):

```bash
export HYDRATION_MATH_ROOT=/home/mrq/git/sdk/packages
export PROPELLER_MARKET_SNAPSHOT=propeller-vault/docs/evidence/route-execution-2026-09-23/market.json
export PROPELLER_ROUTE_EVIDENCE=propeller-vault/docs/evidence/route-execution-2026-09-23/native-baseline.json
node --test-reporter=tap scripts/propeller/route-calibration.test.mjs
node scripts/propeller/route-calibration.mjs "$PROPELLER_MARKET_SNAPSHOT" propeller-vault/docs/evidence/route-execution-2026-09-23/prime-reference.json /tmp/route-calibration-replay.json
```

Run these contract campaigns **serially**, since Forge shares artifacts/cache:

```bash
RETENTION_LOOP_COST_BPS=10 node scripts/propeller/run-retention-campaign.mjs /tmp/propeller-retention-low-cost-20260923
RETENTION_LOOP_COST_BPS=25 node scripts/propeller/run-retention-campaign.mjs /tmp/propeller-retention-20260923
node scripts/propeller/report-route-execution.mjs --run-dir /tmp --output propeller-vault/docs/evidence/route-execution-2026-09-23
```

The last command also requires the native verification, calibration and
regression logs from this pinned run. Do not overwrite those log paths with
results from another fork and reuse old campaign evidence.

## Before Activating

Validate the authoritative PRIME/USD reference and update/freshness policy;
prove executable quotes after pool-peg convergence; confirm replenishment
capacity and loss/bridge funding; enforce admission and harvest-size budgets;
then repeat the lifecycle on an unchanged market that actually satisfies the
approved limits. Production roles, registry wiring, keeper operations and
independent review remain separate release gates.
