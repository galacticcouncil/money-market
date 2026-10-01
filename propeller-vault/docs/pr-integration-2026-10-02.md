# Propeller PR integration checkpoint

**2 October 2026 — review evidence for #60 → #61 → #63. Production activation remains blocked.**

This checkpoint composes Main-debt servicing from #60, bounded settlement from
#61 and unwind sizing from #63. It does not implement #62's separate yield
ownership or deposit/harvest size and rate controls. The September RC evidence
remains historical; the results below cover the combined contract changes.

## Changes and ordering

| PR | Review base | Result |
| --- | --- | --- |
| [#60](https://github.com/galacticcouncil/money-market/pull/60) | `propeller` | Yield-funded Main interest, earned execution allowance, per-exit debt/cash and late-recovery ownership. |
| [#61](https://github.com/galacticcouncil/money-market/pull/61) | `feat/propeller-interest-buffer` | At most 32 requests settled per call. Its funding fixture funds each exit cohort under #60's ledger rules. |
| [#63](https://github.com/galacticcouncil/money-market/pull/63) | `prop_gaslock` | Routine sales are capped to outstanding unwind needs; met deleveraging targets are cleared; positive rounding tails still request a sale. |

#63 preserves #60's execution-cost accounting. It excludes already reserved
HOLLAR from funds available to another unwind. Upward rounding converts an
outstanding claim into a positive sale target even below one USD-8 or PRIME
unit; it does not silently cancel a small residual claim.

## Verification

The [machine-readable record and log hashes](evidence/pr-integration-2026-10-02/summary.json)
identify the tested commit, compiler settings and runtime templates. The
subsequent #61 merge changes only a test comment; this evidence commit adds docs.

| Check | Result |
| --- | --- |
| Full Solidity suite | **297 passed, zero failed, 11 optional skips** across 42 suites. |
| Focused unwind/Main-debt suites | 33 passed, including eight unwind-sizing cases. |
| Keeper tests and build | 19 tests passed; TypeScript build passed. |
| Settlement gas mock | 401 requests finish in 13 calls; largest call 6,961,307 gas. This is not native throughput evidence. |
| CollateralVault runtime | 24,438 bytes; **138 bytes** below EIP-170. |
| SubLoop runtime | 21,327 bytes; 3,249 bytes below EIP-170. |

The Solidity checks use Solc 0.8.22, optimizer 200, via IR and London EVM output.
Runtime hashes identify compiled templates, not deployed addresses. Optional
campaign/fork setups remain skipped; no fresh native acceptance run or production
deployment was performed for this checkpoint.

Reproduce from `propeller-vault`, with the pinned libraries initialized:

```sh
forge test --offline --evm-version london
```

From `propeller-vault/looper`, install its locked dependencies and run:

```sh
npm test
npm run build
```

## Remaining work

- Revise #62 around separate ownership of unharvested yield while keeping funded
  collateral claims unchanged. A new depositor must not capture earlier earnings;
  an atomic harvest alone does not solve this finding.
- Implement and quantify admission/harvest size and rate controls. The shared
  execution-budget study is a design, not a production control in these PRs.
- Integrate the final reviewed stack through #46 and validate the matching UI
  against the approved deployment, including delayed exits and late recoveries.
- Close the [activation gates](release-candidate.md#activation-gates): oracle
  wiring, strict native entry, funded replenishment, approved limits, recovery
  operations and exact-artifact independent review.

The stack is prepared for review in dependency order. Passing local checks does
not approve public deposits, a TVL limit, governance execution or a mainnet date.
