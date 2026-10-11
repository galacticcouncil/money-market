import collections
import json


def check_rescale_coverage(paths):
    campaigns = []
    required = {"scale_64", "scale_128", "scale_192", "scale_256", "stale_holder_256",
                "stale_request_256", "settled_stale_holder", "started_stale_request",
                "transfer_after_rescale", "revert_after_rescale", "partial_claims", "final_claims",
                "writeoff_after_rescale", "refill_after_writeoff", "funded_harvest_after_writeoff",
                "ceil_account_boundary", "ceil_request_boundary"}
    for path in paths:
        rows = [json.loads(line) for line in path.read_text().splitlines() if line]
        completion = list(map(int, rows[-1]["action"]))
        if completion[0] != 998 or completion[3] != 2 or completion[4] + 2 != len(rows):
            raise SystemExit(f"incomplete rescale trace: {path}")
        features = collections.Counter()
        previous = list(map(int, rows[0]["state"]))
        for row in rows[1:-1]:
            op, caller, owner, receiver, amount = map(int, row["action"])
            code, _ = map(int, row["status"])
            state = list(map(int, row["state"]))
            if code:
                if previous[23]:
                    features["revert_after_rescale"] += 1
            else:
                if state[23] > previous[23]:
                    for scale in (64, 128, 192, 256):
                        if previous[23] < scale <= state[23]:
                            features[f"scale_{scale}"] += 1
                if state[39] == state[22] and state[38] and state[23] - state[40] >= 256:
                    features["stale_holder_256"] += 1
                if state[17] and not state[16] and state[127] == state[22] and state[23] - state[128] >= 256:
                    features["stale_request_256"] += 1
                if state[39] == state[22] and state[23] > state[40]:
                    shift = state[23] - state[40]
                    floor_claim = min(state[20], (state[37] >> shift) +
                                      state[34] * (state[21] - (state[38] >> shift)) // 10**27)
                    if floor_claim != state[36]:
                        features["ceil_account_boundary"] += 1
                if state[17] and not state[16] and state[127] == state[22] and state[23] > state[128]:
                    shift = state[23] - state[128]
                    floor_index = state[126] >> shift
                    ceil_index = (state[126] + (1 << shift) - 1) >> shift
                    floor_claim = min(state[20], (state[125] >> shift) +
                                      state[115] * (state[21] - floor_index) // 10**27)
                    ceil_claim = min(state[20], (state[125] >> shift) +
                                     state[115] * (state[21] - min(state[21], ceil_index)) // 10**27)
                    if floor_claim != ceil_claim:
                        features["ceil_request_boundary"] += 1
                if op == 2 and state[40] == state[23] and state[23] - previous[40] >= 256:
                    features["settled_stale_holder"] += 1
                if op == 5 and state[16] > previous[16] and previous[23] - previous[128] >= 256:
                    features["started_stale_request"] += 1
                if op in (2, 3) and previous[23]:
                    features["transfer_after_rescale"] += 1
                if op == 7:
                    features["partial_claims" if state[114 + 15 * amount + 8] else "final_claims"] += 1
                if state[22] > previous[22] and previous[23] >= 256:
                    features["writeoff_after_rescale"] += 1
                if state[22] and state[20] > previous[20]:
                    features["refill_after_writeoff"] += 1
                if op == 23 and state[22] and state[82] > previous[82]:
                    features["funded_harvest_after_writeoff"] += 1
            previous = state
        missing = sorted(required - features.keys())
        if missing:
            raise SystemExit(f"missing rescale coverage in {path}: {missing}")
        campaigns.append({"seed": completion[1], "depth": completion[2], "steps": len(rows) - 2,
                          "features": dict(sorted(features.items()))})
    summary = {"campaigns": campaigns, "steps": sum(c["steps"] for c in campaigns)}
    (paths[0].parent / "rescale-coverage.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("rescale coverage: " + json.dumps(summary, sort_keys=True))
    return summary


def check_coverage(paths):
    actions = collections.Counter()
    reverts = collections.Counter()
    features = collections.Counter()
    seeds = []
    calls = 0
    vault_calls = 0
    other_calls = 0
    market = paths[0].name.startswith("market-")
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
            if market:
                old_extra = previous[114 + previous[17] * 15 + previous[28] * 5:]
                extra = state[114 + state[17] * 15 + state[28] * 5:]
            calls += 1
            vault_calls += op in (*range(10), 14, 15, 22, 24)
            other_calls += op in (18, 23, 27)
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
                if market:
                    if op == 23 and value:
                        features["harvests"] += 1
                        if state[82] > previous[82]:
                            features["funded_reward_mints"] += 1
                    if op == 24:
                        features["caller_compounds"] += 1
                    if op in (23, 24) and state[5] < previous[5]:
                        features["interest_serviced_by_compound"] += 1
                        if extra[25] - old_extra[25] > 1:
                            features["repayment_retries"] += 1
                    if op == 20 and state[5] > previous[5] and extra[5] > old_extra[5]:
                        features["interest_accrual"] += 1
                    if op == 22 and value:
                        features["peg_topups"] += 1
                    if extra[10] > old_extra[10]:
                        features["source_execution_costs"] += 1
                    if extra[13] > old_extra[13]:
                        features["source_fees_collected"] += 1
                    if extra[14] > old_extra[14]:
                        features["harvest_fees_collected"] += 1
                    if op == 9 and extra[16] > old_extra[16]:
                        features["price_delever_started"] += 1
                    if op == 6 and old_extra[16] and not extra[16]:
                        features["price_delever_completed"] += 1
                    if op == 17 and extra[0] < old_extra[0]:
                        features["source_value_losses"] += 1
                    if op == 27 and old_extra[14 if owner == 0 else 13]:
                        features["protocol_fee_claims"] += 1
                    if extra[11] < old_extra[11]:
                        features["reserve_draws"] += 1
                    if extra[9]:
                        features["unfinished_cost_batches"] += 1
            if state[29] > 0:
                features["unfinished_source_batches"] += 1
            previous = state
    required = ["partial_claims", "final_claims", "redirected_keeper_claims"]
    if any(seed % 4 in (1, 2) for seed in seeds):
        required += ["unfinished_source_batches", "receipts_during_unfinished_batch",
                     "wide_public_start_batches", "settlement_limit_reached"]
    if market:
        required += ["harvests", "funded_reward_mints", "caller_compounds",
                     "interest_serviced_by_compound", "repayment_retries", "interest_accrual",
                     "peg_topups", "source_execution_costs", "source_fees_collected",
                     "harvest_fees_collected", "price_delever_started", "price_delever_completed",
                     "source_value_losses", "protocol_fee_claims"]
        for code in (24, 26):
            if not reverts[code]:
                raise SystemExit(f"missing market guard/revert coverage: {code}")
    for name in required:
        if not features[name]:
            raise SystemExit(f"missing stateful coverage: {name}")
    summary = {"seeds": seeds, "steps": calls, "vault_calls": vault_calls,
               "other_contract_calls": other_calls, "environment_actions": calls - vault_calls - other_calls, "successful_actions": dict(sorted(actions.items())),
               "revert_classes": dict(sorted(reverts.items())), "features": dict(sorted(features.items()))}
    name = "market-coverage.json" if market else "coverage.json"
    (paths[0].parent / name).write_text(json.dumps(summary, indent=2) + "\n")
    print("stateful coverage: " + json.dumps(summary, sort_keys=True))
    return summary
