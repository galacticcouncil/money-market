#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled", action="store_true", help="use already compiled modules from LEAN_PATH")
    args = parser.parse_args()
    formal = Path(__file__).resolve().parent
    vault = formal.parent
    manifest = json.loads((formal / "solidity-manifest.json").read_text())
    for name, expected in manifest["files"].items():
        actual = hashlib.sha256((vault / name).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"source changed: {name}; review the model and update the manifest")
    if not args.compiled:
        subprocess.run(["lake", "build"], cwd=formal, check=True)
    lean = ["lean"] if args.compiled else ["lake", "env", "lean"]
    subprocess.run(lean + ["CheckAxioms.lean"], cwd=formal, check=True)
    for source, artifact in [("ParityVectors.lean", "runtime-vectors.json"),
                             ("CoverageVectors.lean", "coverage-vectors.json"),
                             ("MachineVectors.lean", "machine-vectors.json")]:
        generated = subprocess.check_output(lean + ["--run", source], cwd=formal, text=True)
        if json.loads(generated) != json.loads((formal / artifact).read_text()):
            raise SystemExit(f"{artifact} changed; regenerate it with {source}")
    layout = json.loads(subprocess.check_output(
        ["forge", "inspect", "JuicerYieldAccounting", "storage-layout", "--json", "--offline"], cwd=vault, text=True))
    slots = {entry["label"]: int(entry["slot"]) for entry in layout["storage"]}
    names = ["sourceShares", "protocolShares", "totalUnits", "rewardIndex", "units", "accountIndex",
             "requestIndex", "harvestUnits", "harvestRewardUnits", "harvestProtocolUnits", "epoch",
             "accountEpoch", "requestEpoch", "unitScale", "accountScale", "requestScale", "requestUnits"]
    for slot, name in enumerate(names):
        if slots.get(name) != slot:
            raise SystemExit(f"storage layout changed: {name}")
    subprocess.run(["forge", "test", "--offline", "--match-path", "test/formal/Lean*.t.sol", "-vv"],
                   cwd=vault, check=True)
    print("Lean/Solidity runtime comparisons passed; source fingerprints and vector regeneration match")


if __name__ == "__main__":
    main()
