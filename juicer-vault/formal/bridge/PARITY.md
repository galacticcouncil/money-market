# Verity reference-model scope

The current Solidity correspondence record is [SOLIDITY_PARITY.md](../SOLIDITY_PARITY.md),
including integer accounting and ICE comparisons added on 9 October 2026.

This directory is an older, simplified Verity reference model. It proves selected properties and
demonstrates Lean → Yul → bytecode with external calls. It does not implement current jETH units,
event-driven allocation, deferred deposits, the Main ledger, reserve accounting or ICE execution.

## runnable bytecode evidence

```sh
# from juicer-vault
forge test --match-path test/formal/VerityParity.t.sol --evm-version shanghai
```

Two tests exercise the reference-model deposit's supply/borrow/mint/seed calls and keeper guard
against mocks. They passed with zero skips on 9 October. Shanghai or newer is required because
the bytecode uses PUSH0; the default Paris run skips it.

The uint16 selector and void Aave return-data issues are fixed in the checked-in source/bytecode.
Re-emission needs a Verity compiler with the changes in `AAVE_ECM_DIAGNOSIS.md`. No live-Aave fork
run is established by the mocks.

## assumptions

Matching invariant names does not establish equivalence. The historical zero-LTV synthetic theorem
and current `invariant_noSynthBorrow` assert different properties: synthetic LTV is 100 bps; the
Solidity test checks zero synthetic debt. The old `assets == supply` proof likewise does not cover
the current reward-unit book.

External-call proofs assume external behavior. The solc Yul-to-bytecode step and full deployed
Solidity are outside these proofs. A drop-in ABI/storage match is not implemented.
