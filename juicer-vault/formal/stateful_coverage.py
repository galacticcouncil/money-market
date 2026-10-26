import collections
import json


def check_loss_recovery_coverage(paths):
    campaigns = []
    required = {"loss_carry_recorded", "loss_carry_restored", "waiting_request_during_loss",
                "waiting_request_survived_recovery", "transfer_during_loss_history",
                "partial_claims", "final_claims", "writeoff_after_loss_history",
                "refill_after_writeoff", "funded_harvest_after_writeoff"}
    for path in paths:
        rows = [json.loads(line) for line in path.read_text().splitlines() if line]
        completion = list(map(int, rows[-1]["action"]))
        if completion[0] != 998 or completion[3] != 2 or completion[4] + 2 != len(rows):
            raise SystemExit(f"incomplete loss-recovery trace: {path}")
        features = collections.Counter()
        previous = list(map(int, rows[0]["state"]))
        saw_loss = False
        for row in rows[1:-1]:
            op, caller, owner, receiver, amount = map(int, row["action"])
            code, _ = map(int, row["status"])
            state = list(map(int, row["state"]))
            if state[23] != 0:
                raise SystemExit(f"public loss/recovery unexpectedly rescaled units in {path}")
            carry_before = previous[24] + previous[25]
            carry = state[24] + state[25]
            if not code:
                if carry > carry_before:
                    features["loss_carry_recorded"] += 1
                    saw_loss = True
                if carry_before and carry < carry_before:
                    features["loss_carry_restored"] += 1
                waiting = state[17] > state[16]
                if carry and waiting:
                    features["waiting_request_during_loss"] += 1
                if carry_before and not carry and waiting:
                    features["waiting_request_survived_recovery"] += 1
                if op in (2, 3) and saw_loss:
                    features["transfer_during_loss_history"] += 1
                if op == 7:
                    features["partial_claims" if state[116 + 15 * amount + 8] else "final_claims"] += 1
                if state[22] > previous[22] and saw_loss:
                    features["writeoff_after_loss_history"] += 1
                if state[22] and state[20] > previous[20]:
                    features["refill_after_writeoff"] += 1
                if op == 23 and state[22] and state[84] > previous[84]:
                    features["funded_harvest_after_writeoff"] += 1
            previous = state
        missing = sorted(required - features.keys())
        if missing:
            raise SystemExit(f"missing loss-recovery coverage in {path}: {missing}")
        campaigns.append({"seed": completion[1], "depth": completion[2], "steps": len(rows) - 2,
                          "features": dict(sorted(features.items()))})
    summary = {"campaigns": campaigns, "steps": sum(c["steps"] for c in campaigns)}
    (paths[0].parent / "loss-recovery-coverage.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("loss-recovery coverage: " + json.dumps(summary, sort_keys=True))
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
                old_extra = previous[116 + previous[17] * 15 + previous[30] * 5:]
                extra = state[116 + state[17] * 15 + state[30] * 5:]
            calls += 1
            vault_calls += op in (*range(10), 14, 15, 22, 24)
            other_calls += op in (18, 23, 27, 31, 32)
            # the trace ends with the source's band and admission bound
            banded = tuple(previous[-4:-1]) != (0, 500, 300)
            admission = previous[-1]
            if code:
                reverts[code] += 1
                if op == 31:
                    features["band_rejections"] += 1
                if op == 32:
                    features["admission_rejections"] += 1
                if op == 0 and code == 28 and admission != 50:
                    features["deposits_stopped_by_configured_admission"] += 1
            else:
                actions[op] += 1
                if op == 31:
                    features["band_resets" if (owner, receiver, amount) == (0, 0, 0) else "band_changes"] += 1
                if op == 32 and state[-1] != 50:
                    features["admission_changes"] += 1
                if op == 9 and banded and (state[5] != previous[5] or state[7] != previous[7]):
                    features["banded_rebalances"] += 1
                if op == 0 and admission != 50:
                    features["deposits_under_configured_admission"] += 1
                if op == 7:
                    start = 116 + 15 * amount
                    active = state[start + 8]
                    features["partial_claims" if active else "final_claims"] += 1
                    if caller != previous[start] and receiver != previous[start]:
                        features["redirected_keeper_claims"] += 1
                if op in (2, 3) and previous[34]:
                    features["transfers_during_source_pause"] += 1
                if op == 6 and previous[32]:
                    features["settlement_during_pause"] += 1
                if op == 6 and previous[31] and previous[9] > state[9]:
                    features["receipts_during_unfinished_batch"] += 1
                if op == 6 and state[15] - previous[15] == 32:
                    features["settlement_limit_reached"] += 1
                if op == 5 and state[16] - previous[16] > 64:
                    features["wide_public_start_batches"] += 1
                if market:
                    if op == 23 and value:
                        features["harvests"] += 1
                        if state[84] > previous[84]:
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
                        if banded:
                            features["banded_price_delevers"] += 1
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
            if state[31] > 0:
                features["unfinished_source_batches"] += 1
            previous = state
    required = ["partial_claims", "final_claims", "redirected_keeper_claims", "band_changes",
                "band_resets", "band_rejections", "admission_changes", "admission_rejections",
                "banded_rebalances", "deposits_under_configured_admission"]
    if any(seed % 4 in (1, 2) for seed in seeds):
        required += ["unfinished_source_batches", "receipts_during_unfinished_batch",
                     "wide_public_start_batches", "settlement_limit_reached"]
    if market:
        required += ["harvests", "funded_reward_mints", "caller_compounds",
                     "interest_serviced_by_compound", "repayment_retries", "interest_accrual",
                     "peg_topups", "source_execution_costs", "source_fees_collected",
                     "harvest_fees_collected", "price_delever_started", "price_delever_completed",
                     "source_value_losses", "protocol_fee_claims", "banded_price_delevers"]
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
