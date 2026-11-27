#!/usr/bin/env python3
import re
from pathlib import Path


def compact(text):
    return re.sub(r"\s+", "", text)


def require_once(text, fragment, label):
    count = text.count(compact(fragment))
    if count != 1:
        raise SystemExit(f"dispatch drift: expected one {label}, found {count}")


def main():
    formal = Path(__file__).resolve().parent
    vault = formal.parent
    base = compact((vault / "test/formal/LeanStatefulParity.t.sol").read_text())
    market = compact((vault / "test/formal/LeanMarketStatefulParity.t.sol").read_text())
    lean_path = formal / "JuicerLean/FixedPoint/SolidityDispatch.lean"
    lean = lean_path.read_text()

    base_branches = {
        0: "if (op == 0) data = abi.encodeCall(vault.deposit, (n, actors[b]));",
        1: "else if (op == 1) data = abi.encodeCall(vault.approve, (actors[b], n));",
        2: "else if (op == 2) data = abi.encodeCall(vault.transfer, (actors[b], n));",
        3: "else if (op == 3) data = abi.encodeCall(vault.transferFrom, (actors[a], actors[b], n));",
        4: "else if (op == 4) data = abi.encodeCall(vault.requestRedeem, (n, actors[a]));",
        5: "else if (op == 5) data = abi.encodeCall(vault.startUnwinds, (n));",
        6: "else if (op == 6) data = abi.encodeCall(vault.pokeSettle, ());",
        7: "else if (op == 7) data = abi.encodeCall(vault.claim, (n, actors[b], a == 0 ? type(uint256).max : a));",
        8: "else if (op == 8) data = abi.encodeCall(vault.sync, ());",
        9: "else if (op == 9) data = abi.encodeCall(vault.rebalance, ());",
        10: "else if (op == 10) { vm.warp(block.timestamp + n); _record([op, caller, a, b, n], 0, 0); return; }",
        11: """else if (op == 11) {
            hollar.mint(actors[caller], n);
            vm.prank(actors[caller]); hollar.approve(address(pool), n);
            target = address(pool); data = abi.encodeCall(pool.repay, (address(hollar), n, 2, address(vault)));
        }""",
        12: "else if (op == 12) { target = address(source); data = abi.encodeCall(source.setPullBps, (n)); }",
        13: "else if (op == 13) { target = address(pool); data = abi.encodeCall(pool.setRepayLimit, (n)); }",
        14: "else if (op == 14) data = n == 0 ? abi.encodeCall(vault.unpause, ()) : abi.encodeCall(vault.pause, ());",
        15: "else if (op == 15) data = n == 0 ? abi.encodeCall(vault.unpauseDeposits, ()) : abi.encodeCall(vault.pauseDeposits, ());",
        16: "else if (op == 16) { target = address(source); data = abi.encodeCall(source.setEmergencyPaused, (n != 0)); }",
        31: """else if (op == 31) {
            target = address(source);
            data = abi.encodeCall(source.setRebalanceBand, (address(vault), uint16(a), uint16(b), uint16(n)));
        }""",
        32: "else if (op == 32) { target = address(source); data = abi.encodeCall(source.setAdmissionMaxDeficitBps, (uint16(n))); }",
    }
    market_branches = {
        17: "if (op == 17) { target = address(market); data = abi.encodeCall(market.reprice, (n)); }",
        18: "else if (op == 18) { target = address(fees); data = abi.encodeCall(fees.setProtocolFeeBps, (address(vault), uint16(n))); }",
        19: "else if (op == 19) { target = address(market); data = abi.encodeCall(market.setCostBps, (n)); }",
        20: "else if (op == 20) { target = address(pool); data = abi.encodeCall(pool.accrueInterest, (address(hollar), address(vault), n)); }",
        21: "else if (op == 21) { target = address(pool); data = abi.encodeCall(pool.setPrice, (address(eth), n)); }",
        22: "else if (op == 22) { target = address(vault); data = abi.encodeCall(vault.maintainPeg, ()); }",
        23: """else if (op == 23) {
            uint256[] memory minima = new uint256[](1); minima[0] = n;
            target = address(harvester); data = abi.encodeCall(harvester.harvest, (minima));
        }""",
        24: """else if (op == 24) {
            target = address(vault); data = abi.encodeCall(vault.compound, (address(eth), n, b, \"\"));
        }""",
        25: "else if (op == 25) { target = address(pool); data = abi.encodeCall(pool.setDebtRounding, (a, n)); }",
        27: """else if (op == 27) {
            target = address(fees); data = abi.encodeCall(fees.claimProtocolFees, (a == 0 ? address(eth) : address(hollar)));
        }""",
        28: "else if (op == 28) { target = address(swapper); data = abi.encodeCall(swapper.setHaircut, (n)); }",
        29: "else if (op == 29) { target = address(vault); data = abi.encodeCall(vault.setTvlCap, (n)); }",
    }
    shared_funding = """else if (op == 26 || op == 30) {
        hollar.mint(actors[caller], n);
        vm.prank(actors[caller]); hollar.approve(address(vault.mainDebt()), n);
        JuicerMainDebt m = JuicerMainDebt(address(vault.mainDebt()));
        target = address(m);
        data = op == 26 ? abi.encodeCall(m.fundReserve, (n)) : abi.encodeCall(m.fundPosition, (0, n));
    }"""

    base_perform = base.split(
        "functionperform(uint256op,uint256caller,uint256a,uint256b,uint256n)publicvirtual{", 1
    )[1].split("function_next", 1)[0]
    market_perform = market.split(
        "functionperform(uint256op,uint256caller,uint256a,uint256b,uint256n)publicoverride{", 1
    )[1].split("function_error", 1)[0]
    base_ops = {int(op) for op in re.findall(r"op==(\d+)", base_perform)}
    market_ops = {int(op) for op in re.findall(r"op==(\d+)", market_perform)}
    if base_ops != set(range(17)) | {31, 32}:
        raise SystemExit(f"dispatch drift: Solidity base opcode set is {sorted(base_ops)}")
    if market_ops != set(range(17, 31)):
        raise SystemExit(f"dispatch drift: Solidity market opcode set is {sorted(market_ops)}")

    for op, branch in base_branches.items():
        require_once(base_perform, branch, f"Solidity opcode {op}")
    require_once(base_perform, "address target = address(vault);", "base default target")
    require_once(base_perform, "vm.prank(actors[caller]); (bool ok, bytes memory result) = target.call(data);", "base caller dispatch")
    require_once(base_perform, 'else revert("unknown action");', "base unknown-opcode rejection")
    require_once(market_perform, "if (op <= 16 || op >= 31) { super.perform(op, caller, a, b, n); return; }", "base delegation")
    for op, branch in market_branches.items():
        require_once(market_perform, branch, f"Solidity opcode {op}")
    require_once(market_perform, shared_funding, "Solidity opcodes 26 and 30")
    require_once(market_perform, "vm.prank(actors[caller]); (bool ok, bytes memory result) = target.call(data);", "market caller dispatch")
    require_once(market_perform, 'else revert("unknown market action");', "market unknown-opcode rejection")

    expected_decode = {
        0: "some ⟨.vault, .deposit, a⟩",
        1: "some ⟨.vault, .approve, a⟩",
        2: "some ⟨.vault, .transfer, a⟩",
        3: "some ⟨.vault, .transferFrom, a⟩",
        4: "some ⟨.vault, .requestRedeem, a⟩",
        5: "some ⟨.vault, .startUnwinds, a⟩",
        6: "some ⟨.vault, .pokeSettle, a⟩",
        7: "some ⟨.vault, .claim, a⟩",
        8: "some ⟨.vault, .sync, a⟩",
        9: "some ⟨.vault, .rebalance, a⟩",
        10: "some ⟨.environment, .warp, a⟩",
        11: "some ⟨.pool, .repay, a⟩",
        12: "some ⟨.source, .setPullBps, a⟩",
        13: "some ⟨.pool, .setRepayLimit, a⟩",
        14: "some ⟨.vault, if a.amount = 0 then .unpause else .pause, a⟩",
        15: "some ⟨.vault, if a.amount = 0 then .unpauseDeposits else .pauseDeposits, a⟩",
        16: "some ⟨.source, .setEmergencyPaused, a⟩",
        17: "some ⟨.market, .reprice, a⟩",
        18: "some ⟨.fees, .setProtocolFeeBps, a⟩",
        19: "some ⟨.market, .setCostBps, a⟩",
        20: "some ⟨.pool, .accrueInterest, a⟩",
        21: "some ⟨.pool, .setPrice, a⟩",
        22: "some ⟨.vault, .maintainPeg, a⟩",
        23: "some ⟨.harvester, .harvest, a⟩",
        24: "some ⟨.vault, .compound, a⟩",
        25: "some ⟨.pool, .setDebtRounding, a⟩",
        26: "some ⟨.mainDebt, .fundReserve, a⟩",
        27: "some ⟨.fees, .claimProtocolFees, a⟩",
        28: "some ⟨.swapper, .setHaircut, a⟩",
        29: "some ⟨.vault, .setTvlCap, a⟩",
        30: "some ⟨.mainDebt, .fundPosition, a⟩",
        31: "some ⟨.source, .setRebalanceBand, a⟩",
        32: "some ⟨.source, .setAdmissionMaxDeficitBps, a⟩",
    }
    decode = lean.split("def decodeAction", 1)[1].split("def solidityDispatch", 1)[0]
    actual_decode = {}
    decode_rows = re.findall(r"^\s*\|\s*(\d+)\s*=>\s*(.+)$", decode, re.MULTILINE)
    if len(decode_rows) != 33:
        raise SystemExit(f"dispatch drift: Lean decode table has {len(decode_rows)} numeric rows")
    for op, result in decode_rows:
        actual_decode[int(op)] = compact(result)
    expected_compact = {op: compact(result) for op, result in expected_decode.items()}
    if actual_decode != expected_compact:
        raise SystemExit(f"dispatch drift: Lean decode table differs\nexpected {expected_compact}\nactual {actual_decode}")
    require_once(compact(decode), "| _ => none", "Lean unknown-opcode rejection")

    arguments = compact(lean.split("def SolidityCall.arguments", 1)[1].split("def decodeAction", 1)[0])
    expected_arguments = """(call : SolidityCall) : List Nat :=
      let a := call.action
      match call.selector with
      | .deposit => [a.amount, a.b]
      | .approve | .transfer => [a.b, a.amount]
      | .transferFrom => [a.a, a.b, a.amount]
      | .requestRedeem => [a.amount, a.a]
      | .startUnwinds => [a.amount]
      | .claim => [a.amount, a.b, a.a]
      | .warp | .repay | .setPullBps | .setRepayLimit | .reprice | .setProtocolFeeBps
      | .setCostBps | .accrueInterest | .setPrice | .harvest | .fundReserve
      | .setHaircut | .setTvlCap | .fundPosition | .setAdmissionMaxDeficitBps => [a.amount]
      | .setEmergencyPaused => [(a.amount != 0).toNat]
      | .compound => [a.amount, a.b]
      | .setDebtRounding => [a.a, a.amount]
      | .claimProtocolFees => [(a.a != 0).toNat]
      | .setRebalanceBand => [a.a, a.b, a.amount]
      | _ => []"""
    if arguments != compact(expected_arguments):
        raise SystemExit("dispatch drift: Lean action argument projection differs")

    print("dispatch map passed: 33 opcodes, targets, selectors and action arguments match")


if __name__ == "__main__":
    main()
