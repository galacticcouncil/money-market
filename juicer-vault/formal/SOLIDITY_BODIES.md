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
only unused remappings have changed. these settings are scoped to the formal scripts; ordinary
project build configuration is unchanged.
the remapping update changes compiler metadata. all 11 production contracts retain their
selectors and code lengths; creation and runtime bytes match the previous reviewed artifacts
after zeroing their compiler CBOR metadata blocks, including embedded contract metadata.

this is a source-body proof for one private pure helper. solc parsing, the Python extraction and
the correspondence of the interpreter's operations to Solidity remain trusted. there is no
kernel proof of the Solidity compiler or EVM instruction execution. the other contract bodies,
storage, external calls, reentrancy and upgrade behavior remain outside this interpreter.
