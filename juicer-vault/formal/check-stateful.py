#!/usr/bin/env python3
import argparse
from pathlib import Path
import subprocess
from stateful_coverage import check_coverage, check_rescale_coverage
from compiler_environment import compiler_environment


def main():
    parser = argparse.ArgumentParser(description="replay public Solidity call campaigns in Lean")
    parser.add_argument("--compiled", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--count", type=int, default=8)
    parser.add_argument("--depth", type=int, default=192)
    parser.add_argument("--fixture", choices=["all", "both", "baseline", "market", "rescale"], default="all")
    args = parser.parse_args()
    if args.seed < 1 or not 1 <= args.count <= 8 or args.depth < 192:
        parser.error("seed must be positive, count 1–8, depth at least 192")
    formal = Path(__file__).resolve().parent
    if not args.compiled:
        subprocess.run(["lake", "build"], cwd=formal, check=True)
    env = compiler_environment()
    env.update(LEAN_STATEFUL_SEED=str(args.seed), LEAN_STATEFUL_COUNT=str(args.count),
               LEAN_STATEFUL_DEPTH=str(args.depth))
    lean = ["lean"] if args.compiled else ["lake", "env", "lean"]
    for fixture, contract, prefix in [("baseline", "LeanStatefulParityTest", "trace"),
                                     ("market", "LeanMarketStatefulParityTest", "market"),
                                     ("rescale", "LeanRescaleStatefulParityTest", "rescale")]:
        if args.fixture not in ("all", fixture) and not (args.fixture == "both" and fixture != "rescale"):
            continue
        paths = [formal / ".stateful" / f"{prefix}-{seed}.jsonl"
                 for seed in range(args.seed, args.seed + args.count)]
        for path in paths:
            path.unlink(missing_ok=True)
        subprocess.run(["forge", "test", "--offline", "--match-contract", f"^{contract}$",
                        "--match-test", "test_statefulPublicCalls", "--gas-limit", str(2**40), "-vv"],
                       cwd=formal.parent, env=env, check=True)
        subprocess.run(lean + ["--run", "StatefulReplay.lean"] + [str(p) for p in paths],
                       cwd=formal, check=True)
        (check_rescale_coverage if fixture == "rescale" else check_coverage)(paths)


if __name__ == "__main__":
    main()
