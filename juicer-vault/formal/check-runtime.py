#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from stateful_coverage import check_coverage


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
    layout_out = formal / ".stateful" / "layout-out"
    subprocess.run(["forge", "build", "--offline", "--skip", "test", "--skip", "script",
                    "--extra-output", "storageLayout", "--out", str(layout_out),
                    "--cache-path", str(formal / ".stateful" / "layout-cache")], cwd=vault, check=True)
    layout = json.loads((layout_out / "JuicerYieldAccounting.sol" /
                         "JuicerYieldAccounting.json").read_text())["storageLayout"]
    slots = {entry["label"]: int(entry["slot"]) for entry in layout["storage"]}
    names = ["sourceShares", "protocolShares", "totalUnits", "rewardIndex", "units", "accountIndex",
             "requestIndex", "harvestUnits", "harvestRewardUnits", "harvestProtocolUnits", "epoch",
             "accountEpoch", "requestEpoch", "unitScale", "accountScale", "requestScale", "requestUnits"]
    for slot, name in enumerate(names):
        if slots.get(name) != slot:
            raise SystemExit(f"storage layout changed: {name}")
    main_layout = json.loads((layout_out / "JuicerMainDebt.sol" /
                              "JuicerMainDebt.json").read_text())["storageLayout"]
    main_slots = {entry["label"]: int(entry["slot"]) for entry in main_layout["storage"]}
    for slot, name in enumerate(["allocationAmount", "allocationCost", "allocationTotal",
                                 "allocationWeight", "allocationCursor", "allocationTail"], 13):
        if main_slots.get(name) != slot:
            raise SystemExit(f"Main storage layout changed: {name}")
    traces = [formal / ".stateful" / f"{prefix}-{seed}.jsonl"
              for prefix in ("trace", "market") for seed in range(1, 9)]
    for path in traces:
        path.unlink(missing_ok=True)
    env = os.environ.copy()
    env.update(LEAN_STATEFUL_SEED="1", LEAN_STATEFUL_COUNT="8", LEAN_STATEFUL_DEPTH="192")
    subprocess.run(["forge", "test", "--offline", "--match-path", "test/formal/*.t.sol", "--match-contract", "^(Lean|Rescale)", "--gas-limit", str(2**40), "-vv"],
                   cwd=vault, env=env, check=True)
    subprocess.run(lean + ["--run", "StatefulReplay.lean"] +
                   [str(path) for path in traces],
                   cwd=formal, check=True)
    subprocess.run(lean + ["--run", "ScaledDebtReplay.lean",
                           str(formal / ".stateful" / "scaled-debt.jsonl")],
                   cwd=formal, check=True)
    for contract, test in [
        ("SharedHarvestFormalHarness", "test_repeatedTwoVaultHarvestHistory"),
        ("IceSequenceFormalHarness", "test_longEntryExpiryReconcileAndExitHistory"),
    ]:
        subprocess.run(["forge", "test", "--offline", "--match-path",
                        "test/formal/SharedFlowHarness.t.sol", "--match-contract", contract,
                        "--match-test", test, "--gas-limit", str(2**40), "-vv"],
                       cwd=vault, env=env, check=True)
    check_coverage(traces[:8])
    check_coverage(traces[8:])
    print("Lean/Solidity runtime comparisons passed; source fingerprints and vector regeneration match")


if __name__ == "__main__":
    main()
