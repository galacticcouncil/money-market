# PR #62: separate yield ownership and prompt reinvestment

**Follow-up:** the [three-pass validation](pr62-three-pass-validation-2026-10-02.md)
records the later servicing and keeper fixes, 338 passing Solidity tests, and
fresh native execution. The results below retain their original commit scope.

This implementation keeps funded collateral shares and withdrawal promises
separate from unconverted strategy yield. A depositor entering just before
harvest cannot acquire earlier holders' earnings. Transfers leave already-earned
yield with the sender; waiting withdrawal shares earn until their unwind starts.

The implementation and acceptance rules are in
[yield ownership](yield-ownership.md). This record supersedes the design-only
status in the earlier [#62 model record](evidence/yield-ownership-2026-10-02/summary.json)
and extends the [#60/#61/#63 integration checkpoint](pr-integration-2026-10-02.md).

## Behavior for review

- `PropellerYieldAccounting` checkpoints user and protocol source ownership
  before balances change. A lazy index avoids scanning holders. Losses consume
  unconverted earnings before Main backing; worthless funds reset their epoch,
  and dust after repeated losses triggers lazy accounting-unit rescaling.
- Atomic harvesting burns only the realized owner's source units. Actual output
  pays the vested fee and reserved Main servicing, then supplies collateral and
  mints backed reward shares. Unclaimed funded earnings keep compounding.
- Exits split their owner's reward fund allocation proportionally: source units
  follow the unwind, while funded reward shares vest separately for the owner.
  Exit source fees remain reserved until the source claim closes and fall with
  actual execution costs. Late HOLLAR surplus belongs to the original owner.
- Successful harvests prompt keeper maintenance and reinvestment in the same
  cycle. Earned collateral can increase the HOLLAR/PRIME position below the old
  five-percentage-point LTV trigger. Source ramping excludes carry awaiting
  conversion; harvesting also respects the deployment health-factor floor.
- The companion UI reads estimated earnings and claimable shares from the
  ownership ledger at one block, exposes `claimYield`, and uses `surplusOf` to
  exclude outstanding source fees from claimable HOLLAR.

## Verification

The [machine-readable record and hashed logs](evidence/yield-ownership-implementation-2026-10-02/summary.json)
identify tested contract commit `08620fa3f827285e8c0601144cb535a04af33375`
and companion UI commit `c02aca4b9189256c106a179873e7d82faf884ceb`.

| Check | Result |
| --- | --- |
| Complete Solidity regression | **330 passed, zero failed, 11 optional skips**, covering all 42 test files and 44 suites in four batches. |
| Ownership and checkpoint regressions | 28 ownership tests plus the holder-count gas check; included in the complete run. |
| Cold checkpoint transfer | 481,849 gas with two holders; 481,850 with 102 holders. EVM mock measurement. |
| Source storage prefix | 43 existing entries preserved, one mapping appended; eight checker tests pass. |
| Keeper | 22 tests and TypeScript build pass. |
| UI | Nine accounting tests, full type check, module lint and Vite 8 build pass; GitHub checks and previews pass. |
| UI interfaces | 42 function signatures, return types and mutability annotations match compiled contracts. |
| Readiness tool | TypeScript transpilation and 78 ABI fragments checked; no deployment reads performed. |

All nine production runtime templates match every test batch. Runtime limits are
checked at the same Solc 0.8.22 / London / via IR / optimizer-200 settings:

| Contract | Runtime bytes | EIP-170 headroom | Initcode template bytes |
| --- | ---: | ---: | ---: |
| CollateralVault | 23,087 | 1,489 | 39,276 |
| SubLoop | 22,735 | 1,841 | 22,966 |
| PropellerMainDebt | 16,913 | 7,663 | 29,786 |
| PropellerYieldAccounting | 11,328 | 13,248 | 11,660 |
| PropellerFeeController | 8,960 | 15,616 | 9,402 |
| Harvester | 8,212 | 16,364 | 8,717 |
| CompoundLogic | 15,765 | 8,811 | 15,793 |
| PropellerDiscount | 6,740 | 17,836 | 8,364 |
| SyntheticToken | 4,827 | 19,749 | 5,957 |

Initcode template sizes exclude constructor arguments. These hashes identify
compiler templates, not deployed code with its bound immutable addresses. The
build emits Forge lint advisories; the UI build emits existing chunk-size warnings.

The 401-request settlement mock still drains in 13 passes, with a maximum call
of **7,372,545 gas**. This exceeds the keeper's current fixed 5,000,000 gas setting;
the operation budget must be reconciled with native limits before activation.
This mock is not evidence that the current keeper configuration can drain that
worst-case queue on chain.

Reproduce the Solidity regression from `propeller-vault`, with the pinned
libraries initialized. The final run uses four isolated batches whose selections
cover all 42 test files exactly once; the manifests and logs record each command.
The upgrade-state fingerprint hashes smaller groups to avoid Solc's stack limit.

```sh
for batch in 0 1 2 3; do
  python3 docs/evidence/yield-ownership-implementation-2026-10-02/run-shard.py "$batch"
done
```

The equivalent unfiltered suite can also be invoked normally:

```sh
forge test --offline --evm-version london
```

The production settings are Solc 0.8.22, optimizer 200 and via IR. The explicit
London override is required to reproduce these artifacts. The full suite
includes runtime-size regressions, ownership and fee tests, modeled market
scenarios, bounded settlement, upgrade-state fingerprints and invariants.
Optional native forks and the large campaign are separate checks.

The production build uses `forge build --offline --evm-version london --skip test
--skip script`. Its executable runtime templates are compared against every test
batch, and compiler source hashes are checked against the working tree. All 675
Solidity dependency files were also matched against their pinned Git objects.

The recovery fixtures retain exact full-collateral assertions. A shared source
recapitalization may leave individual vault deficits after owner-specific
withdrawals; those fixtures explicitly fund each remaining active Main cohort
before reopening. This external recovery funding is distinct from the test in
which three exits pay their execution costs entirely from earned PRIME yield.

Keeper checks, from `propeller-vault/looper`:

```sh
node --import tsx --test-reporter=tap test/safety.test.ts
node --import tsx --test-reporter=tap test/rounding.test.ts
npm run build
```

Storage checker tests, from the repository root:

```sh
node --test-reporter=tap scripts/propeller/source-storage.test.mjs
node scripts/propeller/check-source-storage.mjs --artifact propeller-vault/out/SubLoop.sol/SubLoop.json
node scripts/propeller/check-ui-abi.cjs /path/to/hydration-ui propeller-vault/out
```

## Rollout boundary

This is a coordinated **fresh deployment**, not a migration of funded older
vaults. Preserving storage prefixes does not initialize their source cost basis
or historical reward ownership. The Main ledger, ownership module, vault helper,
source, fee controller and Harvester must use the matching implementation.

Review the stack in order: #60 → #61 → #63 → #62 → #46. The companion UI remains
draft until deployment addresses are approved and deposit, harvest, reward
claim, cooldown, partial/final withdrawal and later recovery are rehearsed on
that deployment.

No fresh native acceptance run, independent audit or production activation is
implied by these local checks. Deposit/harvest size and rate controls, approved
retention and slippage policy, oracle wiring, strict native entry, replenishment
and recovery operations remain in the [activation gates](release-candidate.md#activation-gates).
This change does not lower reserves or promise an APY or fixed conversion time.
