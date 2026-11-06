#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from solidity_bodies import BodyError, build, expression, require


SOURCES = {
    "JuicerYieldAccounting": "src/JuicerYieldAccounting.sol",
    "JuicerMainDebt": "src/JuicerMainDebt.sol",
    "CollateralVault": "src/CollateralVault.sol",
    "ExecutionController": "src/ExecutionController.sol",
    "ReentrancyGuard": "../bil-vault/lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol",
    "ReentrancyGuardUpgradeable": "../bil-vault/lib/openzeppelin-contracts-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol",
}
TAGS = {"JuicerYieldAccounting": "accounting", "JuicerMainDebt": "mainDebt",
        "CollateralVault": "vault", "ExecutionController": "controller"}


def named(contract, kind, name):
    matches = [n for n in contract["nodes"] if n.get("nodeType") == kind and n.get("name") == name]
    require(len(matches) == 1, f"missing or ambiguous {kind}: {name}")
    return matches[0]


def selected_contract(artifact, name):
    ast = artifact.get("ast", {})
    require(ast.get("nodeType") == "SourceUnit" and ast.get("absolutePath") == SOURCES[name],
            f"wrong source AST: {name}")
    return named(ast, "ContractDefinition", name)


def block(node, count=None):
    require(node.get("nodeType") == "Block", "expected checked block")
    statements = node.get("statements", [])
    require(count is None or len(statements) == count, "unexpected statement count")
    return statements


def identifier(node, declaration):
    require(node.get("nodeType") in ("Identifier", "IdentifierPath")
            and node.get("referencedDeclaration") == declaration
            and not node.get("overloadedDeclarations"), "unexpected identifier binding")


def call(node, declaration, count=0):
    require(node.get("nodeType") == "FunctionCall" and node.get("kind") == "functionCall"
            and not node.get("tryCall") and not node.get("names"), "unexpected call")
    require(len(node.get("arguments", [])) == count, "unexpected call arguments")
    identifier(node["expression"], declaration)
    return node["arguments"]


def statement_expression(node):
    require(node.get("nodeType") == "ExpressionStatement", "expected expression statement")
    return node["expression"]


def binary(node, operator, common):
    require(node.get("nodeType") == "BinaryOperation" and node.get("operator") == operator
            and not node.get("function") and node.get("commonType", {}).get("typeString") == common
            and node.get("typeDescriptions", {}).get("typeString") == "bool", "unexpected guard comparison")
    return node["leftExpression"], node["rightExpression"]


def conditional(node):
    require(node.get("nodeType") == "IfStatement" and node.get("falseBody") is None,
            "expected guard without else")
    return node["condition"], node["trueBody"]


def revert(node, error):
    require(node.get("nodeType") == "RevertStatement", "expected revert")
    call(node["errorCall"], error["id"])
    require(error.get("parameters", {}).get("parameters") == [], "unexpected error parameters")


def modifier_header(node):
    require(not node.get("virtual") and not node.get("overrides")
            and node.get("visibility") == "internal" and node.get("parameters", {}).get("parameters") == [],
            "unsupported modifier dispatch")


def function_header(node, visibility, mutability, outputs=0):
    require(node.get("implemented") is True and node.get("kind") == "function"
            and not node.get("virtual") and not node.get("modifiers")
            and node.get("visibility") == visibility and node.get("stateMutability") == mutability
            and node.get("parameters", {}).get("parameters") == []
            and len(node.get("returnParameters", {}).get("parameters", [])) == outputs,
            "unsupported guard helper")


def variable(contract, name, kind, mutability):
    node = named(contract, "VariableDeclaration", name)
    require(node.get("stateVariable") is True and node.get("mutability") == mutability
            and node.get("typeDescriptions", {}).get("typeString") == kind, "unexpected guard storage")
    return node


def only_vault(contract):
    modifier = named(contract, "ModifierDefinition", "onlyVault")
    modifier_header(modifier)
    vault = variable(contract, "vault", "address", "immutable")
    guard, placeholder = block(modifier["body"], 2)
    require(placeholder.get("nodeType") == "PlaceholderStatement", "missing modifier continuation")
    condition, failure = conditional(guard)
    caller, expected = binary(condition, "!=", "address")
    require(caller.get("nodeType") == "MemberAccess" and caller.get("memberName") == "sender"
            and caller.get("typeDescriptions", {}).get("typeString") == "address", "expected msg.sender")
    identifier(caller["expression"], -15)
    require(caller["expression"].get("typeDescriptions", {}).get("typeString") == "msg", "expected builtin msg")
    identifier(expected, vault["id"])
    revert(failure, named(contract, "ErrorDefinition", "Unauthorized"))
    return modifier["id"]


def non_reentrant(contract):
    modifier = named(contract, "ModifierDefinition", "nonReentrant")
    modifier_header(modifier)
    status = variable(contract, "_status", "uint256", "mutable")
    require(status.get("visibility") == "private", "guard lock is not private")
    constants = [variable(contract, name, "uint256", "constant") for name in ("_ENTERED", "_NOT_ENTERED")]
    values = []
    for constant in constants:
        literal = constant.get("value", {})
        expression(literal, {})
        require(literal.get("nodeType") == "Literal", "guard constant is not literal")
        values.append(int(literal["value"]))
    before = named(contract, "FunctionDefinition", "_nonReentrantBefore")
    after = named(contract, "FunctionDefinition", "_nonReentrantAfter")
    for function in (before, after):
        function_header(function, "private", "nonpayable")
    enter, placeholder, leave = block(modifier["body"], 3)
    call(statement_expression(enter), before["id"])
    require(placeholder.get("nodeType") == "PlaceholderStatement", "missing modifier continuation")
    call(statement_expression(leave), after["id"])
    check, lock = block(before["body"], 2)
    assertion = statement_expression(check)
    require(assertion.get("nodeType") == "FunctionCall" and assertion.get("kind") == "functionCall"
            and not assertion.get("tryCall") and not assertion.get("names")
            and len(assertion.get("arguments", [])) == 2, "expected builtin require")
    builtin = assertion["expression"]
    require(builtin.get("nodeType") == "Identifier" and builtin.get("referencedDeclaration") == -18
            and builtin.get("name") == "require", "expected builtin require binding")
    condition, reason = assertion["arguments"]
    require(reason.get("nodeType") == "Literal" and reason.get("kind") == "string"
            and reason.get("value") == "ReentrancyGuard: reentrant call", "unexpected reentry error")
    left, right = binary(condition, "!=", "uint256")
    identifier(left, status["id"])
    identifier(right, constants[0]["id"])
    for statement, constant in ((lock, constants[0]), (block(after["body"], 1)[0], constants[1])):
        assignment = statement_expression(statement)
        require(assignment.get("nodeType") == "Assignment" and assignment.get("operator") == "=",
                "expected lock assignment")
        identifier(assignment["leftHandSide"], status["id"])
        identifier(assignment["rightHandSide"], constant["id"])
    getter = named(contract, "FunctionDefinition", "_reentrancyGuardEntered")
    function_header(getter, "internal", "view", 1)
    require(getter["returnParameters"]["parameters"][0].get("typeDescriptions", {}).get("typeString") == "bool",
            "guard getter is not boolean")
    result = block(getter["body"], 1)[0]
    require(result.get("nodeType") == "Return"
            and result.get("functionReturnParameters") == getter["returnParameters"]["id"], "unexpected getter return")
    left, right = binary(result["expression"], "==", "uint256")
    identifier(left, status["id"])
    identifier(right, constants[0]["id"])
    return modifier["id"], values, getter["id"]


def address_conversion(node, declaration):
    require(node.get("nodeType") == "FunctionCall" and node.get("kind") == "typeConversion"
            and not node.get("tryCall") and not node.get("names")
            and len(node.get("arguments", [])) == 1
            and node.get("typeDescriptions", {}).get("typeString") == "address", "expected address conversion")
    target = node["expression"]
    require(target.get("nodeType") == "ElementaryTypeNameExpression"
            and target.get("typeName", {}).get("name") == "address", "unexpected conversion target")
    identifier(node["arguments"][0], declaration)


def transfer_guard(contract, getter):
    function = named(contract, "FunctionDefinition", "_transfer")
    require(function.get("implemented") is True and function.get("visibility") == "internal"
            and function.get("stateMutability") == "nonpayable" and not function.get("virtual")
            and not function.get("modifiers") and function.get("returnParameters", {}).get("parameters") == [],
            "unsupported transfer dispatch")
    args = function["parameters"]["parameters"]
    require([p.get("typeDescriptions", {}).get("typeString") for p in args] == ["address", "address", "uint256"],
            "unexpected transfer parameters")
    fund = named(contract, "VariableDeclaration", "yieldAccounting")
    outer, _ = block(function["body"], 2)
    condition, branch = conditional(outer)
    first_two, third = binary(condition, "&&", "bool")
    first, second = binary(first_two, "&&", "bool")
    for node, parameter, target in ((first, args[0], -28), (second, args[1], -28), (third, args[0], fund["id"])):
        left, right = binary(node, "!=", "address")
        identifier(left, parameter["id"])
        address_conversion(right, target)
    statements = block(branch)
    require(statements, "missing transfer guard")
    locked, failure = conditional(statements[0])
    call(locked, getter)
    revert(failure, named(contract, "ErrorDefinition", "ReentrantTransfer"))


def guarded_prefixes(contract, plans):
    entries = []
    for function in contract["nodes"]:
        if function.get("nodeType") != "FunctionDefinition" or function.get("kind") != "function" \
                or function.get("visibility") not in ("public", "external"):
            continue
        prefix = []
        for modifier in function.get("modifiers", []):
            ref = modifier.get("modifierName", {}).get("referencedDeclaration")
            if ref not in plans:
                break
            identifier(modifier["modifierName"], ref)
            require(not modifier.get("arguments"), "unexpected guard arguments")
            prefix.append(plans[ref])
        if prefix:
            require(function.get("implemented") is True and not function.get("virtual"), "unsupported entry dispatch")
            require(all(not modifier.get("arguments") for modifier in function.get("modifiers", [])),
                    "modifier argument evaluation is outside the guard prefix")
            selector = function.get("functionSelector", "")
            require(len(selector) == 8 and all(c in "0123456789abcdef" for c in selector), "missing selector")
            entries.append((selector, prefix))
    require(len({selector for selector, _ in entries}) == len(entries), "duplicate selector")
    return sorted(entries)


def generated_module(artifacts):
    contracts = {name: selected_contract(artifacts[name], name) for name in SOURCES}
    accounting = only_vault(contracts["JuicerYieldAccounting"])
    main = only_vault(contracts["JuicerMainDebt"])
    regular, regular_values, _ = non_reentrant(contracts["ReentrancyGuard"])
    upgradeable, upgrade_values, getter = non_reentrant(contracts["ReentrancyGuardUpgradeable"])
    transfer_guard(contracts["CollateralVault"], getter)
    plans = {accounting: "accountingOnlyVault", main: "mainOnlyVault",
             regular: "regularNonReentrant", upgradeable: "vaultNonReentrant"}
    lines = ["import JuicerLean.Solidity.Guards", "", "namespace Juicer.Solidity", "",
             "def accountingOnlyVault : GuardPlan := .onlyVault",
             "def mainOnlyVault : GuardPlan := .onlyVault",
             f"def regularNonReentrant : GuardPlan := .nonReentrant {regular_values[0]} {regular_values[1]}",
             f"def vaultNonReentrant : GuardPlan := .nonReentrant {upgrade_values[0]} {upgrade_values[1]}",
             f"def vaultTransferGuard : TransferGuard := ⟨{upgrade_values[0]}⟩", "",
             "def guardPrefix : GuardContract → Nat → List GuardPlan"]
    for name, tag in TAGS.items():
        for selector, prefix in guarded_prefixes(contracts[name], plans):
            lines.append(f"  | .{tag}, 0x{selector} => [{','.join(prefix)}]")
    lines += ["  | _, _ => []", "", "end Juicer.Solidity", ""]
    return "\n".join(lines)


def load_artifacts(directory):
    return {name: json.loads((directory / f"{name}.sol" / f"{name}.json").read_text()) for name in SOURCES}


def main():
    parser = argparse.ArgumentParser(description="check selected solc guard bodies and leading modifier bindings")
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--emit", action="store_true")
    args = parser.parse_args()
    formal = Path(__file__).resolve().parent
    vault = formal.parent
    directory = args.artifacts.resolve() if args.artifacts else formal / ".stateful/ast-out"
    if args.artifacts is None:
        build(vault, directory)
    artifacts = load_artifacts(directory)
    compiler = json.loads((formal / "bytecode-manifest.json").read_text())["contracts"]["CollateralVault"]["summary"]["compiler"]
    for name, artifact in artifacts.items():
        require(artifact.get("metadata", {}).get("compiler", {}).get("version") == compiler, f"unreviewed compiler: {name}")
    generated = generated_module(artifacts)
    if args.emit:
        print(generated, end="")
        return
    manifest = json.loads((formal / "solidity-manifest.json").read_text())["files"]
    for source in SOURCES.values():
        require(hashlib.sha256((vault / source).read_bytes()).hexdigest() == manifest[source], f"guard source changed: {source}")
    require(generated == (formal / "JuicerLean/Solidity/GeneratedGuards.lean").read_text(),
            "Solidity guards changed; review the generated bindings and proofs")
    subprocess.run([sys.executable, str(formal / "check-bytecode.py"), "--artifacts", str(directory)], check=True)
    print("solc guard extraction matches: two onlyVault modifiers, two lock implementations, transfer prefix and entry bindings")


if __name__ == "__main__":
    try:
        main()
    except (BodyError, KeyError, TypeError, IndexError) as error:
        raise SystemExit(f"Solidity guard check failed: {error}") from error
