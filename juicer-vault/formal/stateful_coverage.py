import collections
import json


def check_coverage(paths):
    actions = collections.Counter()
    reverts = collections.Counter()
    features = collections.Counter()
    seeds = []
    calls = 0
    for path in paths:
        rows = [json.loads(line) for line in path.read_text().splitlines() if line]
        completion = [int(n) for n in rows[-1]["action"]]
        if completion[0] != 998 or completion[4] + 2 != len(rows):
            raise SystemExit(f"incomplete stateful trace: {path}")
        seeds.append(completion[1])
        previous = [int(n) for n in rows[0]["state"]]
        for row in rows[1:-1]:
            op, caller, owner, receiver, amount = map(int, row["action"])
            code, value = map(int, row["status"])
            state = [int(n) for n in row["state"]]
            calls += 1
            if code:
                reverts[code] += 1
            else:
                actions[op] += 1
                if op == 7:
                    start = 114 + 15 * amount
                    active = state[start + 8]
                    features["partial_claims" if active else "final_claims"] += 1
                    if caller != previous[start] and receiver != previous[start]:
                        features["redirected_keeper_claims"] += 1
                if op in (2, 3) and previous[32]:
                    features["transfers_during_source_pause"] += 1
                if op == 6 and previous[30]:
                    features["settlement_during_pause"] += 1
                if op == 6 and previous[29] and previous[9] > state[9]:
                    features["receipts_during_unfinished_batch"] += 1
                if op == 6 and state[15] - previous[15] == 32:
                    features["settlement_limit_reached"] += 1
                if op == 5 and state[16] - previous[16] > 64:
                    features["wide_public_start_batches"] += 1
            if state[29] > 0:
                features["unfinished_source_batches"] += 1
            previous = state
    required = ["partial_claims", "final_claims", "redirected_keeper_claims"]
    if any(seed % 4 in (1, 2) for seed in seeds):
        required += ["unfinished_source_batches", "receipts_during_unfinished_batch",
                     "wide_public_start_batches", "settlement_limit_reached"]
    for name in required:
        if not features[name]:
            raise SystemExit(f"missing stateful coverage: {name}")
    summary = {"seeds": seeds, "calls": calls, "successful_actions": dict(sorted(actions.items())),
               "revert_classes": dict(sorted(reverts.items())), "features": dict(sorted(features.items()))}
    (paths[0].parent / "coverage.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("stateful coverage: " + json.dumps(summary, sort_keys=True))
    return summary
