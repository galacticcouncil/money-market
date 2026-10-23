#!/usr/bin/env bash
# Build and copy LooperFactory/LooperPosition/LooperLogic as hardhat-style artifacts into a hydration-node checkout,
# where integration-tests load them by name.
set -euo pipefail
dest="${1:?usage: export-artifacts.sh <hydration-node-dir>}/scripts/test-contracts/artifacts/contracts"
cd "$(dirname "$0")/.."
forge build
for name in LooperFactory LooperPosition LooperLogic; do
	mkdir -p "$dest/$name.sol"
	jq '{_format: "hh-sol-artifact-1", contractName: "'"$name"'", sourceName: "contracts/'"$name"'.sol", abi, bytecode: .bytecode.object}' \
		"out/$name.sol/$name.json" > "$dest/$name.sol/$name.json"
done
