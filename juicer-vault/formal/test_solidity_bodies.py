import argparse
from copy import deepcopy
import json
from pathlib import Path
import unittest

from solidity_bodies import BodyError, function_body, selected_function


ARTIFACT = Path(__file__).resolve().parent / ".stateful/ast-out/JuicerYieldAccounting.sol/JuicerYieldAccounting.json"


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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifact", type=Path, default=ARTIFACT)
    args = parser.parse_args()
    ARTIFACT = args.artifact
    unittest.main(argv=[__file__])
