# Execution controls and economical keeper validation

This follow-up to PR #62 implements the [deposit/harvest controller and keeper
policy](execution-controls-implementation.md). It is review evidence, not public
activation or an updated APY forecast. The earlier five-round economic model
predates the controller's gas overhead and throughput limits.

## Contract and keeper verification

- Full London regression: **358 passed, zero failed, 12 optional skips** across
  47 suites. The focused controls suite contributes 14 new cases plus three
  inherited harvest cases. It covers initial-deposit rollback, minimum/maximum
  sizes, shared admission/ramp credit, refill, expiry, stale/forked quotes,
  quote deterioration, direct-call bypass rejection, partial harvest ownership,
  partial reinvestment and safety repayment after policy expiry.
- The smaller-harvest regression proves that a bounded slice can satisfy Main
  servicing limits when the full harvest cannot, while leaving the rest invested.
- **39 keeper tests pass**, including zero-work suppression, conservative gas
  budgets, pinned quotes, bounded preview retries, interest-accrual input headroom,
  pending-receipt signer locks and safety repayment despite a failed vault read.
  The TypeScript build passes.
- All **nine** selected production creation/runtime artifacts exactly match the
  complete regression build. Production artifacts use Solc 0.8.22, London, via
  IR and optimizer 200. Dynamic test linking only changes test deployment; its
  reported test gas is not a native execution measurement.
- The conservative source storage gate preserves **43 existing entries** and
  permits the two appended fields relative to the recorded baseline. This is
  not migration approval for a funded older deployment.
- All **42 existing companion UI ABI functions** match the compiled artifacts.
  This does not test the new quote-aware deposit flow, which remains required
  before public activation. Readiness-script syntax/transpilation passes; no
  production readiness result is claimed without an approved policy.

## Native rehearsal

The local fork starts at finalized Hydration block **15,306,846**, runtime **447**,
hash `0x02f6c220e92ae361c69ffbc6fe624c691ce9b9191e49ef5d34d891cdd2f6de7c`.
The existing ETH/tBTC lifecycle campaign passes on a fresh local stack. The
follow-up upgrades its source/vault implementations and replaces its Harvester
with the final artifacts, then installs the controller and illustrative budgets.
The campaign and an additional 1,000 PRIME donation explicitly fund income and
recovery scenarios; they do not establish organic APY or self-financing losses.

Artifact verification checks actual native code and proxy implementation slots.
The current source, vault, helper, Harvester and controller match their final
artifacts after masking constructor immutables. The two Main debt modules have
identical executable code with compiler metadata differences; their immutable
vault, pool, debt-token and accounting-module bindings are checked separately.
This follow-up is not a fresh exact-artifact production deployment rehearsal.

Measured deployment limits:

| Contract | Runtime bytes | Native creation gas | Submitted gas allowance |
| --- | ---: | ---: | ---: |
| Vault including constructor-created helper | 24,086 | 15,216,816 | 16,738,498 |
| Source implementation | 23,981 | 8,860,494 | 9,746,544 |
| Execution controller | 9,813 | 3,717,462 | 4,089,209 |
| Harvester | 9,147 | 3,516,162 | 3,867,779 |

The native transaction cap remains **16,777,216**. The vault creation allowance
has only **38,718 gas** of headroom after its 10% margin; runtime headroom is
490 bytes for the vault and 595 for the source. Any further contract change
needs a fresh size/deployment check.

The mined deposit preview leaves native token balances, scaled debt/aToken
balances, source principal and vault shares unchanged. The initial quote attempts
correctly fail because Chopsticks 2.3 returns millisecond timestamps and
Substrate block hashes. The EVM and public RPC use seconds and EVM block hashes.
The local adapter normalizes timestamps and reads `ethereum.blockHash`; the
[read-only RPC comparison](evidence/execution-controls-2026-10-03/rpc-block-context.json)
records the discrepancy. No chain timestamp, price, oracle floor or quote
tolerance is changed to pass the check. Native call gas estimation uses bounded `eth_call`
search because the local estimator does not reproduce the real call path.

The real keeper rejects a 100-PRIME batch valued at **$106.24** because its
conservative gas estimate is **$0.123**, above the default **0.1%** gas/value
budget. No transaction is submitted. With an explicit local 200-PRIME shared
budget and 100-PRIME per-vault caps, it accepts a **$212.49** batch at the same
cost rule and price floors. The transaction uses **6,161,900 gas**, against an
**8,193,855** allowance. Idle peg maintenance then produces no transaction.
These fixture sizes illustrate the batching decision, not approved mainnet caps.

The quoted deposit uses **2,945,947 gas** against a **4,109,528** allowance.
An oversized initial deposit fails with the controller's `TradeSize` error.
The completed action results and transaction gas are in
[`native-controls.json`](evidence/execution-controls-2026-10-03/native-controls.json).
This native harvest quotes two PRIME-to-collateral lanes; it does not measure a
batch also requiring collateral-to-HOLLAR servicing. That bounded servicing
path passes the Solidity regression and remains part of the exact-deployment
native activation rehearsal. The measured 6.16M gas is not a worst-case ceiling.

## Reproduction and release boundaries

```sh
# From propeller-vault/; select separate directories for each build.
forge build --offline --evm-version london --skip test --skip script --sizes \
  --out /tmp/controls-production/out --cache-path /tmp/controls-production/cache
forge test --offline --evm-version london --dynamic-test-linking \
  --out /tmp/controls-tests/out --cache-path /tmp/controls-tests/cache -vv
cd looper
npm run build
npm test
```

For the native follow-up, use the pinned Galactic Council Chopsticks 2.3.0
runtime fixture and run `native-deploy.mjs`, `native-discount.mjs` and
`native-campaign.mjs` as in the earlier native validation. Then:

```sh
export PROPELLER_ARTIFACT_DIR=/tmp/controls-production/out
export PROPELLER_LOCAL_PORT=8164
node scripts/propeller/native-execution-controls.mjs campaign.json controls.json
node scripts/propeller/native-verify-execution-controls.mjs \
  campaign.json controls.json code-verification.json
```

The controller requires approved per-route sizes, shared refill/burst budgets,
expiry and quote limits. Activation also requires a quote-aware deposit UI,
independent funded operators and alert routing, sustained multi-vault backlog
and handover drills, feed/liquidity/recovery policy, independent review and an
exact-artifact governance rehearsal. Safety monitoring does not replenish pool
inventory, treasury funds or rounding reserves automatically.

The [evidence directory](evidence/execution-controls-2026-10-03/) contains logs,
artifact comparisons, native results and a manifest of their hashes.
