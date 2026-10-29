# Juicer rename (plan step 8)

Propeller becomes Juicer and the shares become jETH/jtBTC, in one rename-only PR
after the logic work (tracks A–E) is merged and before the new Lark rollout. The
rename is one command. This file lists what it maps, what it leaves alone and
why, and what has to happen outside this repository.

This file and `scripts/rename-juicer.mjs` are excluded from the rename, so the
old names below stay readable.

## Run it

With this branch (the script and this file) rebased onto the final `juicer-next`,
on a clean tree:

```sh
node scripts/rename-juicer.mjs --dry-run   # summary, changes nothing
node scripts/rename-juicer.mjs             # git mv + replacements, result staged
node scripts/rename-juicer.mjs --check     # exit 1 on any non-excluded leftover
git diff --cached --stat -M
```

Commit the staged result as the rename commit. Then rebuild, because ignored
build output keeps the old names until it is replaced: `forge clean` before
`forge build` in `juicer-vault`, `npm run build` in `juicer-vault/looper`, and
a fresh `lake build` in `juicer-vault/formal`.

How the script behaves:

- It reads `git ls-files`, so it covers whatever the tracks added, and it never
  touches submodules (`lib/`, `bil-vault/lib/`). Rules are patterns, not a file
  list.
- It refuses a dirty tree unless `--allow-dirty` is passed.
- Directories move with one `git mv` each, so untracked content (`node_modules`,
  `out/`, `cache/`, `.lake`) moves with them.
- It never opens a real `.env*` file. Committed `*.example` templates are
  edited.
- It is idempotent: a second run finds nothing to do.

## Mapping

Text and path rules, applied in order outside the exclusions below:

| Rule | Example |
| ---- | ------- |
| `PROPELLER` → `JUICER` | `PROPELLER_ROUNDING_RESERVES` → `JUICER_ROUNDING_RESERVES` |
| `Propeller` → `Juicer` | `PropellerMainDebt` → `JuicerMainDebt`, "Propeller ETH" → "Juicer ETH" |
| `propeller` → `juicer` | `propeller-vault` → `juicer-vault`, `«propeller-lean»` → `«juicer-lean»` |
| `pETH` → `jETH` (also `wpETH` → `wjETH`) | share symbol |
| `ptBTC` → `jtBTC` | share symbol |
| `pBTC` → `jBTC` | test-only share symbol |
| `psHOL…` → `jsHOL…` | synthetic: `psHOLLAR` → `jsHOLLAR`, Lark `psHOL-OCT` → `jsHOL-OCT` |
| `aPS…`, `vdPS…`, `sdPS…` → `aJS…`, `vdJS…`, `sdJS…` | synthetic reserve tokens: `aPSYNTH` → `aJSYNTH`, Lark `aPS-OCT` → `aJS-OCT` |
| `` `p${…}` `` → `` `j${…}` `` | Lark share symbol template `` `p${name}-OCT` `` |
| `pVault`, `pShares` → `jVault`, `jShares` | comment shorthand for vault shares |

The symbol rules match whole tokens only. Nothing else named `p…` (prices,
pools) is touched. The synthetic and reserve-token symbols were not decided
explicitly; they follow the share pattern. Drop their rules to keep the old
symbols.

What that produces:

| Area | Before | After |
| ---- | ------ | ----- |
| Directories | `propeller-vault/`, `scripts/propeller/`, `propeller-rebalancer/`, `formal/PropellerLean/` | `juicer-vault/`, `scripts/juicer/`, `juicer-rebalancer/`, `formal/JuicerLean/` |
| Contracts | `PropellerMainDebt`, `PropellerYieldAccounting`, `PropellerDiscount`, `PropellerFeeController` | `JuicerMainDebt`, `JuicerYieldAccounting`, `JuicerDiscount`, `JuicerFeeController` (file names follow) |
| Interfaces | `IPropellerDiscount`, `IPropellerFeeController` | `IJuicerDiscount`, `IJuicerFeeController` |
| Tests | `PropellerDiscountTest`, `PropellerDiscountForkTest`, `PropellerInvariantTest` and their files | `JuicerDiscountTest`, `JuicerDiscountForkTest`, `JuicerInvariantTest` |
| Share tokens | "Propeller ETH" `pETH`, "Propeller tBTC" `ptBTC` | "Juicer ETH" `jETH`, "Juicer tBTC" `jtBTC` |
| Synthetic | "Propeller Synthetic HOLLAR" `psHOLLAR`; reserve "Propeller aSynth" `aPSYNTH`, `vdPSYNTH`, `sdPSYNTH` | "Juicer Synthetic HOLLAR" `jsHOLLAR`; "Juicer aSynth" `aJSYNTH`, `vdJSYNTH`, `sdJSYNTH` |
| Lark deploy (`lark-deploy.mjs`, `lark-wire.mjs`) | "Propeller ETH October" `pETH-OCT`, `pTBTC-OCT`, "Propeller October HOLLAR" `psHOL-OCT`, `aPS-OCT` | "Juicer ETH October" `jETH-OCT`, `jTBTC-OCT`, "Juicer October HOLLAR" `jsHOL-OCT`, `aJS-OCT` |
| Keeper | package `propeller-looper`, class `PropellerLooper` | `juicer-looper`, `JuicerLooper` |
| Lark bots | package `propeller-lark-bots`, health file `/tmp/propeller-bot-health.json` | `juicer-lark-bots`, `/tmp/juicer-bot-health.json` (Dockerfile and bot together) |
| Rebalancer | package `propeller-rebalancer`, `scripts/propeller-rebalancer.mjs` | `juicer-rebalancer`, `scripts/juicer-rebalancer.mjs` |
| Docker images | `galacticcouncil/propeller-lark-keeper`, `galacticcouncil/propeller-lark-bots`, `galacticcouncil/propeller-looper` | `galacticcouncil/juicer-lark-keeper`, `galacticcouncil/juicer-lark-bots`, `galacticcouncil/juicer-looper` |
| Swarm | stack `propeller-looper`, label `com.hydration.role: propeller-looper`, config key `propeller_manifest`, config `propeller-lark4-${DEPLOYMENT}-manifest-v3` | `juicer-looper`, `juicer-looper`, `juicer_manifest`, `juicer-lark4-${DEPLOYMENT}-manifest-v3` |
| Env vars | 42 `PROPELLER_*` names (`PROPELLER_ROUNDING_RESERVES`, `PROPELLER_VAULTS`, `PROPELLER_SYNTH`, `PROPELLER_LOCAL_PORT`, …) | `JUICER_*`, same suffixes |
| Governance task | `tasks/proposals/propeller.ts`, `npx hardhat propeller` | `tasks/proposals/juicer.ts`, `npx hardhat juicer` |
| Deploy record names | `SyntheticToken-Propeller`, `SubLoop-Propeller`, `Harvester-Propeller`, `PropellerFeeController-Propeller` | `…-Juicer`, `JuicerFeeController-Juicer` |
| Lean | lake package `propeller-lean`, library `PropellerLean`, namespace `Propeller` | `juicer-lean`, `JuicerLean`, `Juicer` |
| CI | `propeller-keeper.yml` "Propeller keeper"; job `propeller` "Propeller contracts" | `juicer-keeper.yml` "Juicer keeper"; job `juicer` "Juicer contracts" |
| Scratch paths | `/tmp/propeller-*` defaults, `mkdtemp` prefixes | `/tmp/juicer-*` (dated ones excepted, below) |
| Scripts | `scripts/propeller-*.mjs` (26 older top-level scripts) | `scripts/juicer-*.mjs` |

## Not renamed

### Excluded files

These keep their content and basename. Their parent directory is still renamed,
so they move to `juicer-vault/…`.

| Rule | Files | Why |
| ---- | ----- | --- |
| `*/docs/evidence/**` | raw evidence | Logs, JSON and checksums of what was run and deployed. Summaries hash these bytes. |
| date in the file name (`YYYY-MM-DD` or `YYYYMMDD`; md, json, log, txt, csv, svg, html) | dated reports, the audit report, fixtures, the ICE spike result | Records of a specific run. Future dated reports from the tracks fall under the same rule. |
| self-declared historical docs | `coupled-liquidity-checkpoint`, `hollar-peg-liquidity`, `interest-policy-comparison`, `main-debt-verification`, `market-stress-90d`, `operating-buffer`, `operating-buffer-verification`, `pr60-completion`, `prime-pricing-replenishment`, `principal-safety-history`, `release-candidate`, `route-execution-calibration` | Each opens with "historical", "archive" or a dated checkpoint. They quote test names, commands and numbers of that time. |
| `docs/next-version-plan.md` | the plan | It describes the rename itself ("Propeller → Juicer", "set the share symbols (`pETH`/`ptBTC`)"). Rewritten, it would read "Juicer → Juicer". |
| `audit/`, `deployments/`, `x-ray/`, `AUDIT.md`, `formal/BRIDGE_SPIKE.md` | audit ledger and report, Lark 4 journal and address registry, x-ray snapshot, Verity spike | Real addresses with the names deployed under them, or dated snapshots. |
| `PROPELLER-MAINNET-HANDOVER.md` | root handover | Marked "historical lark-4 handover". |
| `scripts/rename-juicer.mjs`, `docs/rename-juicer.md` | the rename itself | — |

Consequences:

- Relative links inside excluded docs that point at renamed files (for example
  `../src/PropellerMainDebt.sol`, `../../scripts/propeller/…`) no longer
  resolve. They describe the tree at their date; read them at their commit.
- The report generators (`scripts/juicer/report-*.mjs`, `summarize-*.mjs`) now
  look up `Juicer*` artifact keys, so they cannot regenerate an old report from
  its old evidence. Check out the report's commit for that.

### Strings kept inside renamed files

| Kept | Where | Why |
| ---- | ----- | --- |
| `//Alice//propeller-20261005-arb`, `//Alice//propeller-20261007-pools`, `//Alice//propeller-20261007-replay` | lark-bots, `scripts/juicer/lark-*` | sr25519 derivation input. Renaming changes the signer accounts and their EVM bindings and inventory. Fresh bot accounts on the new Lark are a deliberate choice for track D. The rule covers any `//<name>//propeller…` path, so new signers should get their final name from the start. |
| `.propeller-bot.secret` | `.gitignore` | Renaming it would un-ignore an existing secret file in someone's checkout. |
| Dated artifact names: `/tmp/propeller-…-20260923.log`, `propeller-${name}-20260923`, `/tmp/propeller-lark-20261005.json`, `/tmp/propeller-routes-20260923.sqlite`, … | report and record scripts | They name specific historical runs and journals. |
| `galacticcouncil/propeller-lark-*@sha256:…`, stack `propeller-oct2026` | `scripts/juicer/lark-record.mjs` | Facts about the Lark 4 deployment: a digest lives in its old repository. |
| `PropellerOperatingBuffer` | `docs/main-debt-servicing.md` | Removed contract, mentioned as history. |
| URLs | everywhere | UI preview `…/strategies/propeller`, GitHub blobs on `feat/propeller`. |
| Paths into other checkouts | `scripts/juicer/ice-spike/run.mjs`, `scripts/verity-*.mjs`, lark-2 fork scripts | `/home/mrq/git/money-market-prop-carry/…`, `/home/mrq/git/aave-v3-deploy/propeller-vault/…`, `/home/mrq/git/aave-propeller-wt/…` are other working trees. |
| Git branches | docs | `propeller`, `feat/propeller-interest-buffer`, `ys-propeller-fixes`. |
| Garden notes | Lean headers | `note-propeller-impl` keeps its name. |
| hydration-ui paths | `scripts/juicer/check-ui-abi.cjs` | `apps/main/src/modules/strategies/propeller/config/abi.ts` is the UI's path until #4120 renames it. |
| Third-party code | `lib/`, `bil-vault/lib/`, `node_modules` | Submodules and packages are never edited. |

### Hashed and on-chain strings

| String | Changes? | Note |
| ------ | -------- | ---- |
| Role ids (`ADMIN_ROLE`, `UPGRADER_ROLE`, `GUARDIAN_ROLE`, `VAULT_ROLE`, `MINTER_ROLE`, `RATE_ADMIN_ROLE`, `keccak256("ADMIN_ROLE")` in the Main ledger) | no | None contains the product name. |
| Storage slots | no | No named or ERC-7201 slots. Only type labels such as `contract IPropellerFeeController` change in storage-layout output. The SubLoop baseline (`evidence/source-upgrades-2026-09-23/subloop-storage.json`) has none, so `check-source-storage.mjs` is unaffected. |
| EIP-712 domains | none exist | No permit or typed data, so the share name is not hashed anywhere. |
| Share and synthetic ERC20 name/symbol | yes, deliberately | Set in `initialize` and the constructor, so fresh deployments only. Lark 4 keeps `pETH-OCT`/`pTBTC-OCT`/`psHOL-OCT`. |
| Asset-registry name/symbol of the synthetic | yes, deliberately | Registered per chain at listing. Registry names are unique, and the new Lark has none yet. |
| Aave reserve token names/symbols | yes, deliberately | Set by `initReserves` at listing. |
| Hardhat-deploy record names | yes | No records are tracked. Rename any local `deployments/<net>/*-Propeller.json`, or pass the `JUICER_*` address overrides. |
| Swarm config, stack and image names | yes, for new stacks | Lark 4's live objects keep their names (below). |
| sr25519 derivation paths | no | See above. |
| Contract names in bytecode | metadata only | Dry run: runtime and creation code is byte-identical after stripping the CBOR metadata. Sizes are unchanged. |

## Dry run

Run on 9 October against `juicer-next` at `4feffdd`, before tracks A–E land.
The result is on the unmerged branch `juicer-rename-dryrun`.

- **Diff:** 791 paths and 907 changed lines (+907/−907). There are 4 directory
  moves and 38 file renames, and 572 files move without edits. 210 files carry
  1,097 replacements. Step 8 will be somewhat larger, because of the files the
  tracks add.
- **`--check`** passes. A second run moves nothing and edits nothing.
- **Forge:** clean via-IR build of the same 155 files. The full suite gives 388
  passed, 0 failed and 13 skipped (401). That matches the base test for test,
  and gas matches exactly on all 367 non-fuzz tests.
- **Bytecode:** runtime and creation code of all 12 `src` contracts is
  byte-identical to the base once the CBOR metadata is stripped.
- **Compatibility:** the SubLoop storage check passes (43 preserved entries).
  `check-ui-abi.cjs` against hydration-ui `feat/juicer` passes 45 signatures.
- **Keeper:** `npm run build` passes; `npm test` 57/57.
- **Lark bots:** 11/11.
- **Scripts:** 74 pass, 1 fail and 50 skip, the same as the base. The one
  failure, `route-calibration.test.mjs`, cannot find
  `@galacticcouncil/math-stableswap` at the repository root. `rounding-native`
  passes 3/3. Root `tsc` shows the base's 88 errors (missing typechain) and no
  others. All 167 JS files parse.
- **References:** no new unresolved import or link in renamed files. Six links
  in excluded docs now dangle, as expected: two in
  `coupled-liquidity-checkpoint.md` and four in
  `PROPELLER-MAINNET-HANDOVER.md`.
- **Lean** (there is no `.lake` here): all 13 `JuicerLean.*` imports resolve.
  `lakefile.toml`, `lake-manifest.json` and the root module agree on
  `juicer-lean`/`JuicerLean`, and `namespace Juicer`/`end Juicer` balance in
  every file.

## Outside this repository

- **Lark 4.** Keep operating it from `money-market-prop-carry` at a pre-rename
  commit. That checkout tracks `juicer-next`, so do not pull the rename into it
  while Lark 4 runs. The renamed tooling no longer finds Lark 4's journal
  (`/tmp/propeller-lark-20261007.json`), swarm configs
  (`propeller-lark4-20261007-manifest-*`), stack (`propeller-oct2026`) or
  images (`propeller-lark-*`).
- **New Lark (track D, step 9).** `lark-deploy.mjs` builds names and symbols
  from the reserve keys as "Juicer ${name} October" and `j${name}-OCT`, which
  gives `jETH-OCT` and `jTBTC-OCT`. If the new Lark should carry the final
  `jETH`/`jtBTC`, set them there; that is a deployment choice, not part of the
  rename. The bot signers keep their `//Alice//propeller-…` paths unless D
  picks new ones.
- **hydration-ui #4120** (`feat/juicer`):
  - `apps/main/tests/propeller-abi.mjs` reads
    `PropellerMainDebt.sol/PropellerMainDebt.json` (likewise
    `PropellerYieldAccounting` and `PropellerFeeController`). Rename the group
    keys to `Juicer*`. Function and event signatures are unchanged; only the
    `internalType` labels in the ABI JSON change.
  - `config/vaults.ts` `shareSymbol` `pETH`/`ptBTC` → `jETH`/`jtBTC`, with
    the new Lark addresses.
  - When the UI renames `modules/strategies/propeller/`, update the path in
    `scripts/juicer/check-ui-abi.cjs`.
- **Docker Hub:** create `galacticcouncil/juicer-lark-keeper`,
  `galacticcouncil/juicer-lark-bots` and `galacticcouncil/juicer-looper`, and
  push new builds there. The `propeller-lark-*` repositories must keep Lark 4's
  pinned digests.
- **Swarm (new Lark):** deploy under `juicer-*` stack and config names, with
  env keys `JUICER_*`.
- **Env files and shells:** rename `PROPELLER_*` keys to `JUICER_*` in local
  `.env*` files and operator environments. The script does not open them.
- **GitHub settings:** if branch protection requires "Propeller contracts" or
  the "Propeller keeper" workflow, switch it to "Juicer contracts" and "Juicer
  keeper".
- **Garden:** the Propeller status, impl and rebrand notes cite
  `propeller-vault/…` and `scripts/propeller/…` paths. Update them once the
  PR merges. Note filenames stay.
- **`deployments/README.md`** stays as the Lark 4 record. Add the new Lark
  under the Juicer names at step 9.
