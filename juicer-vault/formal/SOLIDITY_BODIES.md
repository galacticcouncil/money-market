# Solidity body correspondence

`solidity_bodies.py` extracts `JuicerYieldAccounting._shiftIndex` from the actual solc 0.8.22 AST
and checks it against `JuicerLean/Solidity/GeneratedBodies.lean`. identifiers are bound by
declaration ID and parameter order. unsupported expressions, widths, statements, unchecked
blocks, modifiers and override dispatch are rejected. the compiler version and current source
fingerprint are checked, together with the production artifact manifest.

`JuicerLean/Solidity/Expressions.lean` interprets the accepted typed expression tree with
checked uint256 inputs, addition and subtraction, unsigned right shifts, equality and lazy
conditional evaluation. these operations follow the [Solidity 0.8.22 integer and shift
rules](https://docs.soliditylang.org/en/v0.8.22/types.html#integers). `eval_valid` proves every
successful word result is within uint256; `choose_true` and `choose_false` prove the unused
conditional branch does not execute.

`accountingShiftIndex_refines` proves evaluation of the extracted body succeeds and equals
`Runtime.ceilShift` for every uint256 index and shift. this includes zero, the maximum word,
and shifts at least 256; `accountingShiftIndex_wide` proves the latter return zero for a zero
index and one otherwise. the arithmetic proof includes the subtraction and addition checks.

```sh
python3 solidity_bodies.py
python3 test_solidity_bodies.py
lake build
lake env lean CheckAxioms.lean
```

`--emit` prints a regenerated Lean expression for review. checking never overwrites the
accepted expression. the runtime gate builds AST-bearing production artifacts, checks the
expression and runs 14 extractor boundary tests before the existing Solidity comparisons.

the formal scripts use `compiler-remappings.json` with automatic remapping discovery disabled.
cache directories include a digest of that file: Foundry can otherwise reuse an artifact when
only unused remappings have changed. each build selects its cache through the environment,
which takes precedence over `--cache-path`; production AST/layout builds therefore cannot replace
the test cache. these settings are scoped to the formal scripts; ordinary
project build configuration is unchanged.
the remapping update changes compiler metadata. all 11 production contracts retain their
selectors and code lengths; creation and runtime bytes match the previous reviewed artifacts
after zeroing their compiler CBOR metadata blocks, including embedded contract metadata.

this expression proof covers one private pure helper. solc parsing, the Python extraction and
the correspondence of the interpreter's operations to Solidity remain trusted. there is no
kernel proof of the Solidity compiler or EVM instruction execution. the other arithmetic bodies,
storage and external calls remain outside this expression interpreter.

## guard prefixes

`solidity_guards.py` checks the compiled AST of the accounting and Main `onlyVault` modifiers,
the regular and upgradeable OpenZeppelin reentrancy guards, and the vault's explicit `_transfer`
guard. it binds storage references, internal calls and modifier uses by declaration ID, checks
statement order, and rejects extra guard statements, repeated continuations, override dispatch,
unknown helper calls and modifier argument evaluation. the remaining function body is opaque.

`GeneratedGuards.lean` records the checked guards and 32 leading modifier prefixes: seven
accounting, eleven Main, eleven vault and three execution-controller entrypoints. the checker
stops at the first unsupported modifier. functions with an outer `onlyRole` are consequently
outside this prefix table; an empty entry means no coverage, not unrestricted access. inherited
ERC20 entrypoints are also outside the table.

| contract | covered leading prefixes |
| --- | --- |
| `JuicerYieldAccounting` | `checkpoint`, `settle`, `escrow`, `startExit`, `beginHarvest`, `splitHarvest`, `retainServicingSurplus` |
| `JuicerMainDebt` | `fundPosition`, `fundReserve`, `withdrawReserve`, `beforeDeposit`, `borrowed`, `startExit`, `expectDelever`, `creditSource`, `repay`, `harvest`, `claimSurplus` |
| `CollateralVault` | `deposit`, `requestRedeem`, `startUnwinds`, `pokeSettle`, `claim`, `compound`, `sync`, `burnYieldShares`, `rebalance`, `maintainPeg`, `fundRoundingReserve` |
| `ExecutionController` | `execute`, `preview`, `previewBounded` |

`Guards.lean` models [modifier nesting](https://docs.soliditylang.org/en/v0.8.22/contracts.html#function-modifiers),
authorization failure, setting the lock before the continuation, clearing it on success, and
call-frame rollback on failure. `GuardProofs.lean` proves:

- every covered accounting entry rejects a caller other than its immutable vault;
- every covered vault entry rejects an already-held lock and resets the lock after success;
- the exact Main `startExit` prefix checks vault authority before reentrancy, and controller
  `execute` rejects reentry;
- ordinary transfers reject a held lock, with the exact exemptions for transfers from or to
  the vault and transfers from the accounting fund;
- composing the guards with the raw public-call model preserves `PublicInvariant`, including
  rollback, under the existing invariant and `ValidSolidityAction` input premises;
- the same composition preserves account/request epoch and scale metadata from input metadata
  alone, for every raw action, including rollback and unsupported opcodes.

the transfer result concerns the first check in the internal `_transfer` body. it does not prove
dispatch from inherited `transfer`/`transferFrom`, or safety of the exempt paths. error classes
are abstracted; revert payloads and gas are not modeled. rollback is an assumed call-frame rule,
not an EVM storage-journal proof. the `status` field represents the guard's private storage;
successful continuations return normally. nonlocal assembly exits, arbitrary assembly/delegatecall
writes and hostile callbacks that change this state are not proved safe. the public-call composition
proves the model wrapper, not correspondence of each
remaining Solidity function body.

the runtime gate checks these bindings and 24 rejection/mutation tests against the same pinned
production artifacts. the two OpenZeppelin guard sources are included in the fingerprint set.

```sh
python3 solidity_guards.py
python3 test_solidity_guards.py
```

role membership and role administration, proxy/upgrader authorization and implementation
compatibility, arbitrary external callbacks, the deployed Aave Pool and solver behavior remain
open boundaries. these guard proofs do not establish whole-protocol reentrancy safety.
