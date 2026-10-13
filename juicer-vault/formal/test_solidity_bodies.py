import argparse
from copy import deepcopy
import json
from pathlib import Path
import unittest

from solidity_bodies import (BodyError, STATEFUL_TARGETS, _stateful_function, all_nodes,
                             function_body, selected_function, stateful_body)


ARTIFACT = Path(__file__).resolve().parent / ".stateful/ast-out/JuicerYieldAccounting.sol/JuicerYieldAccounting.json"
ARTIFACTS = ARTIFACT.parent.parent


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


class BodyBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = selected_function(json.loads(ARTIFACT.read_text()))
        cls.expected = function_body(cls.original)

    def setUp(self):
        self.function = deepcopy(self.original)

    def rejected(self):
        with self.assertRaises(BodyError):
            function_body(self.function)

    def test_unchecked_block_rejected(self):
        self.function["body"]["nodeType"] = "UncheckedBlock"
        self.rejected()

    def test_extra_statement_rejected(self):
        self.function["body"]["statements"].append({"nodeType": "ExpressionStatement"})
        self.rejected()

    def test_modifier_rejected(self):
        self.function["modifiers"] = [{"modifierName": {"name": "onlyVault"}}]
        self.rejected()

    def test_override_dispatch_rejected(self):
        self.function["virtual"] = True
        self.rejected()

    def test_narrow_parameter_rejected(self):
        self.function["parameters"]["parameters"][0]["typeDescriptions"] = {
            "typeIdentifier": "t_uint128", "typeString": "uint128"}
        self.rejected()

    def test_storage_reference_rejected(self):
        identifier = next(n for n in nodes(self.function["body"]) if n.get("nodeType") == "Identifier")
        identifier["referencedDeclaration"] = -1
        self.rejected()

    def test_external_call_rejected(self):
        self.function["body"]["statements"][0]["expression"]["nodeType"] = "FunctionCall"
        self.rejected()

    def test_overloaded_operator_rejected(self):
        binary = next(n for n in nodes(self.function["body"]) if n.get("nodeType") == "BinaryOperation")
        binary["function"] = 123
        self.rejected()

    def test_left_shift_rejected(self):
        shift = next(n for n in nodes(self.function["body"]) if n.get("operator") == ">>")
        shift["operator"] = "<<"
        self.rejected()

    def test_literal_units_rejected(self):
        literal = next(n for n in nodes(self.function["body"]) if n.get("nodeType") == "Literal")
        literal["subdenomination"] = "ether"
        self.rejected()

    def test_tuple_expansion_rejected(self):
        wrapper = next(n for n in nodes(self.function["body"]) if n.get("nodeType") == "TupleExpression")
        wrapper["components"].append(deepcopy(wrapper["components"][0]))
        self.rejected()

    def test_return_binding_rejected(self):
        self.function["body"]["statements"][0]["functionReturnParameters"] = -1
        self.rejected()

    def test_parameter_order_changes_term(self):
        self.function["parameters"]["parameters"].reverse()
        self.assertNotEqual(function_body(self.function), self.expected)

    def test_changed_guard_changes_term(self):
        guard = self.function["body"]["statements"][0]["expression"]["condition"]
        literal = guard["rightExpression"]
        literal["value"] = "1"
        literal["typeDescriptions"] = {"typeIdentifier": "t_rational_1_by_1", "typeString": "int_const 1"}
        self.assertNotEqual(function_body(self.function), self.expected)


class StatefulBodyBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.targets = []
        for target in STATEFUL_TARGETS:
            artifact = json.loads((ARTIFACTS / f"{target['contract']}.sol" /
                                   f"{target['contract']}.json").read_text())
            function = _stateful_function(artifact, target)
            cls.targets.append((target, function, stateful_body(function, target)))

    def test_all_selected_bodies_are_bound(self):
        self.assertEqual(len(self.targets), 5)
        self.assertEqual({target["function"] for target, _, _ in self.targets},
                         {"deposit", "beginHarvest", "splitHarvest", "startUnwinds", "pokeSettle"})

    def test_inline_assembly_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        function["body"]["statements"].append({"nodeType": "InlineAssembly"})
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_unchecked_block_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        function["body"]["statements"].append({"nodeType": "UncheckedBlock", "statements": []})
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_selector_change_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        function["functionSelector"] = "00000000"
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_modifier_order_change_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        function["modifiers"].reverse()
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_override_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        function["virtual"] = True
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_signature_change_rejected(self):
        target, original, _ = self.targets[1]
        function = deepcopy(original)
        function["parameters"]["parameters"][0]["typeDescriptions"]["typeString"] = "uint128"
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_missing_semantic_anchor_rejected(self):
        target, original, _ = self.targets[0]
        function = deepcopy(original)
        call = next(node for node in all_nodes(function["body"])
                    if node.get("nodeType") == "MemberAccess" and node.get("memberName") == "beforeDeposit")
        call["memberName"] = "differentCall"
        with self.assertRaises(BodyError):
            stateful_body(function, target)

    def test_supported_extra_statement_changes_digest(self):
        target, original, checked = self.targets[3]
        function = deepcopy(original)
        function["body"]["statements"].append({"nodeType": "Continue"})
        changed = stateful_body(function, target)
        self.assertNotEqual(changed["digest"], checked["digest"])
        self.assertNotEqual(changed["trace"], checked["trace"])

    def test_loops_and_state_updates_are_visible(self):
        traces = {target["function"]: checked["trace"] for target, _, checked in self.targets}
        self.assertIn(("loop", "while", 1), traces["startUnwinds"])
        self.assertTrue(any(kind == "loop" and label == "while" for kind, label, _ in traces["pokeSettle"]))
        self.assertTrue(any(kind == "write" and label == "sourceShares"
                            for kind, label, _ in traces["beginHarvest"]))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=Path, default=ARTIFACT)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.artifacts:
        ARTIFACTS = args.artifacts
        ARTIFACT = ARTIFACTS / "JuicerYieldAccounting.sol/JuicerYieldAccounting.json"
    else:
        ARTIFACT = args.artifact
        ARTIFACTS = ARTIFACT.parent.parent
    unittest.main(argv=[__file__])
