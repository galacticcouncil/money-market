# PR #62: three iterative validation passes

This follows the initial [implementation checkpoint](pr62-completion-2026-10-02.md).
The passes test accounting, native deployability, execution, and conversion
economics. Findings from each pass change the next pass's implementation or
acceptance checks. This is a review record, not production activation.

Tested contracts: `be347ca4501486288a6c452d3cfdcd9e325451f8`.
Final keeper and harness: `9e0f40c5b40efb73f430394d16ac06176c048ed7`
(contract sources unchanged).
The [evidence manifest](evidence/yield-ownership-three-pass-2026-10-02/summary.json)
links the regression logs, native results, source pin and artifact hashes.

## Pass 1: accounting and executable budgets

Ownership/Main regressions passed. The 401-request mock queue drained in 13
passes, but its largest call used 7,372,545 gas, above the keeper's fixed
5,000,000 allowance. The live gas quote also exceeded its fixed gas price.

The keeper now simulates and estimates each operation, adds 20% gas and price
margins, and caps submission at the smallest of its configured budget, the
block allowance, and Hydration's 16,777,216 transaction cap. The initial 12M
operator budget was subsequently calibrated against native queues in pass 3.
Failed estimates and reverted receipts cannot count as successful maintenance.
This prevents knowingly invalid submissions; it does not guarantee arbitrary
queue or route sizes fit.

The next pass used real runtime deployment and swaps, not mock gas alone.

## Pass 2: native deployment and real swap friction

The native rehearsal forks finalized Hydration block **15,306,846**, hash
`0x02f6c220e92ae361c69ffbc6fe624c691ce9b9191e49ef5d34d891cdd2f6de7c`,
runtime **447**, chain **222222**. Runtime code and transaction limits are
unchanged. All writes target isolated localhost Chopsticks forks.

The first vault-plus-helper creation exhausted 12M gas. Estimation plus a 20%
margin exceeded the native transaction cap even though the public block limit
is 45M. The deployment harness now checks complete initcode, explicit London
artifact hashes, the transaction cap, and a separate 10% creation margin.

Real harvest then exposed a servicing defect: reserving Main interest at oracle
value did not cover both PRIME-to-collateral and collateral-to-HOLLAR execution
costs. ETH Main retained 0.000333799714271602 HOLLAR interest despite ample fresh
yield. The fix makes this harvest's net reward output available for servicing,
without accessing previously funded collateral. Any unused HOLLAR allowance
releases a matching source claim back to the existing reward owners. A new
regression applies 60bp friction on both swaps and checks both full interest
service and protection against a newcomer taking that released value.

The next pass rebuilt every artifact and deployed a fresh stack because the
yield module is immutable.

## Pass 3: final implementation and economic behavior

The complete Solidity regression covers all **43 test files / 45 suites**:
**338 passed, zero failed, 11 optional skips**. The skips are the eight large
campaign cases, two separately configured native forks, and one optional
Verity case. Native acceptance is exercised separately below. Four test batches
match all nine production runtime templates; all 54 compiler source hashes
match the source tree. The new mixed-action fuzz test executes 257 cases
(8,224 deposit/income/transfer/harvest/claim actions including a saved seed).
Tiny underfunded entry is expected to reject, not silently dilute backing.

Keeper checks: **29 tests and TypeScript build pass**. Storage checks: **eight
tests, 43 preserved entries and one appended mapping**. The companion UI's
**42 ABI signatures** still match; this pass does not repeat its prior full
build or activate its draft deployment.

The fresh native campaign passed strict entry, deposits, two-vault harvesting,
cooldown/freeze/resume, partial/final settlement, collateral claims, and later
HOLLAR surplus claims for four positions across ETH and tBTC. Both Main ledgers
had exactly zero interest after the corrected harvest. Deployed bytecode,
constructor helper/module bindings and proxy slots match the selected artifacts.

The native ownership stress case donated source income, checkpointed, transferred
collateral shares and harvested through the actual keeper. Earlier earnings
remained with the sender and were claimable as funded collateral shares. After
five repayment cycles cleared the earlier source claims, keeper reinvestment
increased ETH Main debt from **72.7997 to 661.8367 HOLLAR** and its source shares
from **1.63234 to 18.13219**. This demonstrates earned collateral funding a new
HOLLAR/PRIME position on the native runtime; it remains a donated-income fixture.

| Native operation | Receipt gas used |
| --- | ---: |
| Vault implementation plus helper creation | 14,574,486 |
| Main ledger plus yield module creation | 10,875,690 |
| Two-vault harvest with interest servicing | 8,504,478 |
| Fully funded 32-request settlement | 10,985,168 |
| Eight-request unwind start through keeper | 5,587,013 |
| Eight-request settlement through keeper | 3,258,461 |

The larger queue exposed a second budget constraint: `startUnwinds(16)` used
11,524,598 receipt gas, and the 32-request settlement reverted at 12M gas but
succeeded in simulation at 13.3M. Receipt gas reflects refunds; it is not the
required upfront allowance. The final keeper defaults to the native transaction
cap, retains its 20% estimate margin, and starts eight requests at a time for
additional headroom. Its actual 32-request settlement submitted **16,362,510**
gas and advanced the FIFO head from 2 to 34. No contract or native gas limit was
relaxed. An operator choosing a lower budget must verify queue progress under it.
The reduced eight-request start submitted 7,565,498 gas, and its subsequent
settlement submitted 5,052,065; both native transactions passed. Across the
ownership, repayment, reinvestment and queue checks, all **42 keeper submissions**
succeeded under the chain cap. The 40 queue cohorts use explicit recovery funds
to isolate execution cost; they do not demonstrate independently funded exits.

The vault deployment submitted 16,031,935 gas, below the 16,777,216 cap. The
largest runtime remains the vault at 23,087 bytes (1,489 bytes of EIP-170 room);
the source is 22,735 bytes. The yield module is 12,230 bytes. Compiler settings
are Solc 0.8.22, London, via IR, optimizer 200. Complete creation calldata,
including constructor arguments, was checked and executed natively.

### Conversion delay remains an economic gate

A daily 180-day model accrues both actual mock debt balances and source income,
harvests whenever eligible, and immediately attempts Main/source reinvestment.
These are explicit assumptions, not a PRIME APY forecast or native liquidity
simulation. Start: one ETH; assumed PRIME income APR 5%, borrowing APR 2%.

| Execution reserve assumption | First source harvest | First added collateral | Harvests / 180 days | Added ETH / 180 days |
| --- | ---: | ---: | ---: | ---: |
| Current 100bp | Day 113 | Day 123 | 34 | 0.0201920 |
| 10bp sensitivity | Day 13 | Day 13 | 84 | 0.0614829 |

Both cases had a two-day gap from the first source harvest to the second. A
negative spread (2% income / 5% borrowing) produced no collateral harvest in
180 days. Separate yield ownership prevents entry-timing dilution while value
awaits conversion; it does not create surplus or remove retained execution costs.

The favorable 2% borrowing model is not the pinned live rate: HOLLAR variable
borrowing was approximately **4.4017% APR**. PRIME's Aave supply rate was about
0.03576% APR, excluding intrinsic PRIME value growth. This is insufficient data
to assert a positive live net APY.

Native pinned route probes at $1–$1,000 implied roughly 3.88–4.07bp loss for
HOLLAR-to-aPRIME, 44.39–61.01bp for PRIME-to-ETH, and 81.85–98.40bp for
PRIME-to-tBTC. Reverse aPRIME-to-HOLLAR probes up to $5,000 implied 4.11–5.03bp.
The $5,000 direct PRIME-to-collateral probe lacked fixture balance; it is not
evidence of a liquidity ceiling. These results do **not** justify setting all
routes to 10bp. No production risk/slippage parameter was lowered.

Actual keeper receipts also show why eligibility alone is not an economic size
policy. At the pinned WETH/PRIME prices, a $1,104 gross fixture harvest used
about $0.087 of gas. A later $1.30 gross harvest used about $0.081: roughly 6.2%
before swap costs, fees and follow-up maintenance. Gas is paid by the keeper;
it is an operating cost rather than an automatic deduction from users' shares.
An approved minimum net-value/maximum gas-share policy remains necessary.

### Native test boundaries

Fixtures include public development accounts, local governance/deployer and
custody permissions, route wiring, donated PRIME income, source entry/recovery
funds and Main recovery funds. The native campaign's unwind tranche is 900
PRIME, with 1,000 HOLLAR deployment tranches; these are measured rehearsal
parameters, not an approved production policy. Oracle values and 100bp swap
floors are unchanged. Full collateral payout with recovery funding is not proof
of a self-financing strategy under every loss scenario.

Chopsticks 2.3.0's estimate-mode RPC can report an unsuccessful estimate as gas
usage. A checkpoint reported 24,925,469 while a native runtime call in normal
execution mode succeeded using 706,698 gas. The stress harness uses bounded
normal-mode simulations, as Hydration's
[`rpc-binary-search-estimate` build](https://github.com/galacticcouncil/hydration-node/blob/c08bba3689450788ea4bec671146f485d856e74b/Cargo.toml) does,
and retains both runtime and transaction gas limits. Native receipts, not the
erroneous estimate, determine actual execution evidence.

## Reproduction and release boundary

Build artifacts explicitly; do not use an old default `out/` directory:

```sh
cd propeller-vault
forge build --offline --evm-version london --skip test --skip script \
  --out /tmp/propeller-production-out --cache-path /tmp/propeller-production-cache \
  src ../bil-vault/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol
for batch in 0 1 2 3; do
  python3 docs/evidence/yield-ownership-implementation-2026-10-02/run-shard.py \
    "$batch" /tmp/propeller-regression
done
cd looper
node --import tsx --test --test-isolation=none test/*.test.ts
npm run build
```

The native scripts require `PROPELLER_ARTIFACT_DIR`, a pinned London
`PROPELLER_ADAPTER_ARTIFACT`, `PROPELLER_LOCAL_PORT`, and a local fork with the
documented fixtures. Run `native-deploy`, `native-discount`, `native-campaign`,
then `native-verify`, all against the same result JSON. The queue/ownership
stress script additionally requires the `NativeQueueActor` test artifact.
Use Chopsticks 2.3.0 and the archived `native-fixed-chopsticks.yml` fork pin;
build the actor with `forge build --offline --evm-version london
test/helpers/NativeQueueActor.sol` into a separate explicit artifact directory.
The adapter is the [previously pinned route implementation](route-execution-calibration.md)
from `galacticcouncil/aave-debt-swap`, commit
`ddc883efe18ddb6bb90a40d370f3280f51bda0d8` (its artifact hash is in the native result).
Set `PROPELLER_TEST_UNWIND_PRIME=900` for the recorded campaign; omitting it
retains the harness's older 100-PRIME default and changes repayment throughput.

Production remains a **fresh coordinated deployment** of the matching stack.
Independent review/audit, governance/oracle/custody wiring, replenishment and
recovery operations, and approved deposit/harvest size and rate controls remain
release gates. The measured conversion delay also requires an explicit economic
policy decision before claiming prompt BTC/ETH accumulation. No mainnet
activation, treasury action, or production transaction was performed.
