import argparse
from copy import deepcopy
from pathlib import Path
import unittest

from solidity_guards import BodyError, generated_module, load_artifacts, named, selected_contract


ARTIFACTS = Path(__file__).resolve().parent / ".stateful/ast-out"


class GuardBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = load_artifacts(ARTIFACTS)
        cls.expected = generated_module(cls.original)

    def setUp(self):
        self.artifacts = deepcopy(self.original)

    def node(self, contract, kind, name):
        return named(selected_contract(self.artifacts[contract], contract), kind, name)

    def modifier(self, contract, name):
        return self.node(contract, "ModifierDefinition", name)

    def helper(self, contract, name):
        return self.node(contract, "FunctionDefinition", name)

    def rejected(self):
        with self.assertRaises(BodyError):
            generated_module(self.artifacts)

    def test_current_artifacts_match_reviewed_guards(self):
        generated = Path(__file__).resolve().parent / "JuicerLean/Solidity/GeneratedGuards.lean"
        self.assertEqual(self.expected, generated.read_text())

    def test_wrong_vault_comparison_rejected(self):
        self.modifier("JuicerYieldAccounting", "onlyVault")["body"]["statements"][0]["condition"]["operator"] = "=="
        self.rejected()

    def test_wrong_caller_rejected(self):
        self.modifier("JuicerMainDebt", "onlyVault")["body"]["statements"][0]["condition"]["leftExpression"]["memberName"] = "origin"
        self.rejected()

    def test_wrong_vault_binding_rejected(self):
        self.modifier("JuicerMainDebt", "onlyVault")["body"]["statements"][0]["condition"]["rightExpression"]["referencedDeclaration"] = -1
        self.rejected()

    def test_mutable_vault_rejected(self):
        self.node("JuicerMainDebt", "VariableDeclaration", "vault")["mutability"] = "mutable"
        self.rejected()

    def test_missing_only_vault_continuation_rejected(self):
        self.modifier("JuicerYieldAccounting", "onlyVault")["body"]["statements"].pop()
        self.rejected()

    def test_repeated_continuation_rejected(self):
        statements = self.modifier("ReentrancyGuard", "nonReentrant")["body"]["statements"]
        statements.insert(2, deepcopy(statements[1]))
        self.rejected()

    def test_lock_after_body_rejected(self):
        statements = self.modifier("ReentrancyGuardUpgradeable", "nonReentrant")["body"]["statements"]
        statements[0], statements[1] = statements[1], statements[0]
        self.rejected()

    def test_missing_reentry_check_rejected(self):
        self.helper("ReentrancyGuard", "_nonReentrantBefore")["body"]["statements"].pop(0)
        self.rejected()

    def test_shadowed_require_rejected(self):
        self.helper("ReentrancyGuard", "_nonReentrantBefore")["body"]["statements"][0]["expression"]["expression"]["referencedDeclaration"] = 12345
        self.rejected()

    def test_wrong_lock_slot_rejected(self):
        self.helper("ReentrancyGuardUpgradeable", "_nonReentrantBefore")["body"]["statements"][1]["expression"]["leftHandSide"]["referencedDeclaration"] = -1
        self.rejected()

    def test_missing_lock_reset_rejected(self):
        self.helper("ReentrancyGuard", "_nonReentrantAfter")["body"]["statements"].clear()
        self.rejected()

    def test_wrong_reset_constant_rejected(self):
        entered = self.node("ReentrancyGuard", "VariableDeclaration", "_ENTERED")["id"]
        self.helper("ReentrancyGuard", "_nonReentrantAfter")["body"]["statements"][0]["expression"]["rightHandSide"]["referencedDeclaration"] = entered
        self.rejected()

    def test_virtual_getter_rejected(self):
        self.helper("ReentrancyGuardUpgradeable", "_reentrancyGuardEntered")["virtual"] = True
        self.rejected()

    def test_changed_constant_changes_plan(self):
        literal = self.node("ReentrancyGuard", "VariableDeclaration", "_ENTERED")["value"]
        literal.update(value="3", typeDescriptions={"typeIdentifier": "t_rational_3_by_1", "typeString": "int_const 3"})
        self.assertNotEqual(generated_module(self.artifacts), self.expected)

    def test_removed_entry_modifier_changes_bindings(self):
        self.helper("CollateralVault", "deposit")["modifiers"].pop(0)
        self.assertNotEqual(generated_module(self.artifacts), self.expected)

    def test_swapped_modifiers_change_bindings(self):
        self.helper("JuicerMainDebt", "beforeDeposit")["modifiers"].reverse()
        self.assertNotEqual(generated_module(self.artifacts), self.expected)

    def test_unknown_outer_modifier_is_not_claimed(self):
        modifiers = self.helper("CollateralVault", "deposit")["modifiers"]
        modifiers.reverse()
        self.assertNotEqual(generated_module(self.artifacts), self.expected)

    def test_modifier_argument_rejected(self):
        self.helper("CollateralVault", "deposit")["modifiers"][1]["arguments"] = [{"nodeType": "FunctionCall"}]
        self.rejected()

    def test_transfer_condition_change_rejected(self):
        self.helper("CollateralVault", "_transfer")["body"]["statements"][0]["condition"]["operator"] = "||"
        self.rejected()

    def test_transfer_recipient_exemption_change_rejected(self):
        function = self.helper("CollateralVault", "_transfer")
        function["body"]["statements"][0]["condition"]["leftExpression"]["rightExpression"]["leftExpression"]["referencedDeclaration"] = function["parameters"]["parameters"][0]["id"]
        self.rejected()

    def test_effect_before_transfer_guard_rejected(self):
        statements = self.helper("CollateralVault", "_transfer")["body"]["statements"][0]["trueBody"]["statements"]
        statements.insert(0, deepcopy(statements[1]))
        self.rejected()

    def test_transfer_guard_getter_binding_rejected(self):
        guard = self.helper("CollateralVault", "_transfer")["body"]["statements"][0]["trueBody"]["statements"][0]
        guard["condition"]["expression"]["referencedDeclaration"] = -1
        self.rejected()

    def test_transfer_guard_else_rejected(self):
        guard = self.helper("CollateralVault", "_transfer")["body"]["statements"][0]["trueBody"]["statements"][0]
        guard["falseBody"] = {"nodeType": "Block", "statements": []}
        self.rejected()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, default=ARTIFACTS)
    args = parser.parse_args()
    ARTIFACTS = args.artifacts
    unittest.main(argv=[__file__])
