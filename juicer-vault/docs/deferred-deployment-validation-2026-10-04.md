# Deferred deposits and price-aware execution — 4 October 2026

PR #62 now supplies deposited collateral and mints funded shares before any
borrowing or swap. Keeper rebalances borrow only an executable slice. All
controlled buy, harvest, servicing and source-unwind routes have fresh quotes,
size limits and a total MM-oracle shortfall bound. No production policy or
deployment is activated by this change.

## Behavior and accounting

- `reinvestAssets` is pooled borrowing credit for deposits and compounded yield.
  It is not a per-user queue or an exact deployment percentage. Exiting shares
  remove their proportional pending credit. Waiting exits block new deployment.
- Existing funded collateral claims and separate ownership of earlier earnings
  remain intact. Partially harvested earnings remain with their original owners.
- Controller price bounds include swap fees and slippage. Zero is the strict
  default: oracle price or better. Tests additionally exercise a configured 10bp
  limit; that is not an approved launch setting.
- Shared volume credit, expiry, minimum spacing and a same-block restriction
  prevent users/operators from multiplying a route's allowance. An atomic
  harvest can share a group's remaining credit across its legs.
- Ordinary sizing compares the full quote and up to six smaller inputs,
  including the minimum. It selects the largest input near the best sampled
  unit prices, checking servicing legs and retaining active harvest recipients.
  This is bounded sampling, not a global price optimum.
- Urgent source repayment uses the first acceptable quote. Its explicitly
  configured safety lane can bypass optional pacing/volume/expiry, but never
  the price floor, quote or per-trade size bound. Cash-only repayment stays
  directly callable. An unfavorable market can still delay a required swap.
- Operators pay gas by default. Keeper profitability gates exclude it, while
  native transaction limits, estimates, useful-work checks and receipt locks
  remain enforced. Extra source leverage waits for refreshed state after a
  successful Main rebalance.

## Validation

The [evidence directory](evidence/deferred-deployment-2026-10-04/) contains logs,
native receipts, exact bytecode comparisons and a SHA-256 manifest.

| Check | Result |
| --- | --- |
| Full Solidity regression | 367 passed, 0 failed, 13 optional skips, 48 suites |
| Keeper tests | 48 passed; TypeScript build and Node 22 CI command passed |
| Source storage checks | 8 tests passed; 43 baseline entries preserved, 2 previously appended entries |
| Production/test artifacts | All 10 selected creation and runtime bytecodes match exactly |
| Companion UI | Five rounds; 66 tests (32 Propeller), TypeScript, lint, build, browser checks, 45 functions and 4 events match |

Legacy fixtures now explicitly deploy their collateral before testing leveraged
positions. New tests cover debt-free large deposits, partial deployment, exit
before/after partial deployment, shared credit, pacing, stale quotes, stricter
harvest/unwind floors and atomic rollback. Invariants exercise keeper deployment.
The partial-deployment exit test also preserves the existing funding guard for
USD8 source rounding: a fractional deficit blocks another borrow until source
income covers it. No principal tolerance was widened.

Build: Foundry 1.5.1, Solc 0.8.22, London, via IR, optimizer 200. Runtime sizes:
CollateralVault **24,096 bytes**, SubLoop **24,534 bytes** (only **42 bytes** of
EIP-170 headroom), ExecutionController **13,009 bytes**. Further source changes
require a fresh size check. Storage compatibility is not a migration safety proof.

## Native Hydration rehearsal

Fresh local Chopsticks fork of `hdx.tarn`, block **15,306,846**, runtime **447**,
chain ID **222222**. The exact production contracts, proxies, immutable helpers
and ledgers were deployed. Vault-plus-helper creation used **14,719,056 gas**
with a **16,190,962** allowance, below the **16,777,216** transaction cap.
Controller creation used **4,887,198 gas**. No code-size or gas-limit relaxation.

Local fixtures fund the public development account, list/configure synthetic
collateral, protect custody accounts from dust and donate the rounding reserve.
The withdrawal delay is zero only for this rehearsal. The existing PRIME/HOLLAR
oracle references and market prices were not changed.

| Mined operation | Gas used |
| --- | ---: |
| Direct 2 ETH deposit, zero HOLLAR debt/source shares | 568,361 |
| Request withdrawal before deployment | 369,486 |
| Start withdrawal | 434,424 |
| Settle collateral | 432,685 |
| Claim promised collateral | 114,826 |

The remaining deposit stayed debt-free after five reverted entry previews at
50, 25, 10, 5 and 1 HOLLAR, all using the strict zero-shortfall floor at block
15,306,892. Each returned `DispatchFailed()`. This records **no executable entry
at that snapshot**; that generic router error alone does not isolate its cause.
No strategy swap was executed in this fresh native rehearsal. It proves deposit,
withdrawal and rollback behavior, not productive throughput, arbitrage recovery
or organic APY. Accepted staged swaps, harvests and safety paths have Solidity
mock coverage; native execution at approved launch settings remains a gate.

The rehearsal exposed an estimation integration issue: the installed viem helper
omits the requested gas ceiling, so Chopsticks estimates against a 25M default.
Its single-call estimates vary with the supplied ceiling and materially exceed
mined gas. The harness and keeper now send `eth_estimateGas` with an explicit
ceiling reserving the 20% margin, then require successful simulation at the actual
submission allowance. Estimation failures never cause a fixed-gas fallback.

## Review and activation status

[UI PR #3978](https://github.com/galacticcouncil/hydration-ui/pull/3978), commit
`4d238aab93671e7e91e85177af4c55466cc3ee20`, requires
`deferredDeployment() == true`, deposits directly, and shows pooled pending
collateral separately from unconverted yield. Remote CI, CodeQL and preview
builds pass. Deployment addresses are unchanged; no real-wallet rehearsal.

This is a **fresh-deployment candidate**. The new controller consumer ABI and
immutable Main debt/compound components must be deployed together. Existing
one-time controller bindings cannot simply be replaced; migration of an older
controlled stack needs its own reviewed plan.

Independent review, approved lane sizes/spacing/refill/price bounds, liquidity
and oracle calibration, exact governance/address wiring, keeper handover and a
full native-wallet lifecycle remain release gates. A strict floor can leave
capital idle; no 7% APY or new optimized APY is established here. Earlier model
reports retain their recorded revision and assumptions. The optional mainnet
model harness now starts deposits debt-free, but its campaigns were not rerun.

Hosted Foundry CI remains blocked by the effective organization Actions policy:
the allowlist still omits
`foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09`.
Local passing tests do not make that hosted check green. No merge or production
activation was performed.

## Reproduce

```sh
cd propeller-vault
forge build --offline --evm-version london --skip test --skip script --sizes \
  --out out-production --cache-path cache-production
forge build ../bil-vault/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol \
  --offline --evm-version london --out out-production --cache-path cache-production
forge test --offline --evm-version london --dynamic-test-linking -vv
cd looper
npm ci
npm run build
npm test
```

For a fresh isolated fork, set `PROPELLER_ARTIFACT_DIR` to that London output and
an explicit `PROPELLER_LOCAL_PORT`, then run `native-deploy.mjs`,
`native-discount.mjs`, and `native-deferred-deposit.mjs` against the same fresh
result JSON. The last script is scoped to this deposit rehearsal, not the older
`native-execution-controls.mjs` lifecycle.
