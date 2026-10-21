#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from compiler_environment import compiler_environment, compiler_cache_path


SOURCE = "src/JuicerYieldAccounting.sol"
CONTRACT = "JuicerYieldAccounting"
FUNCTION = "_shiftIndex"

STATEFUL_TARGETS = (
    {
        "source": "src/CollateralVault.sol", "contract": "CollateralVault", "function": "deposit",
        "selector": "6e553f65", "semantic": "vaultDeposit", "visibility": "external",
        "mutability": "nonpayable", "parameters": ["uint256", "address"], "returns": ["uint256"],
        "modifiers": ["nonReentrant", "whenNotPaused"],
        "anchors": [("call", "beforeDeposit"), ("call", "checkpoint"), ("call", "totalAssets"),
                    ("call", "_previewShares"), ("call", "_mint"), ("call", "functionDelegateCall"),
                    ("write", "reinvestAssets"), ("call", "_coverRounding"), ("emit", "Deposited")],
    },
    {
        "source": "src/JuicerYieldAccounting.sol", "contract": "JuicerYieldAccounting",
        "function": "beginHarvest", "selector": "1def7faa", "semantic": "accountingBeginHarvest",
        "visibility": "external", "mutability": "nonpayable", "parameters": ["uint256"], "returns": [],
        "modifiers": ["onlyVault"],
        "anchors": [("call", "harvestableShares"), ("branch", "if"), ("revert", "InvalidHarvest"),
                    ("write", "harvestUnits"), ("write", "harvestRewardUnits"),
                    ("write", "harvestProtocolUnits"), ("write", "sourceShares"),
                    ("write", "protocolShares")],
    },
    {
        "source": "src/JuicerYieldAccounting.sol", "contract": "JuicerYieldAccounting",
        "function": "splitHarvest", "selector": "ad81f8c0", "semantic": "accountingSplitHarvest",
        "visibility": "external", "mutability": "nonpayable", "parameters": ["uint256"],
        "returns": ["uint256", "uint256", "uint256"], "modifiers": ["onlyVault"],
        "anchors": [("branch", "if"), ("revert", "InvalidHarvest"), ("write", "reward"),
                    ("write", "fee"), ("write", "service"), ("call", "_fee"),
                    ("write", "harvestUnits"), ("write", "harvestRewardUnits"),
                    ("write", "harvestProtocolUnits")],
    },
    {
        "source": "src/CollateralVault.sol", "contract": "CollateralVault", "function": "startUnwinds",
        "selector": "1b727f39", "semantic": "vaultStartUnwinds", "visibility": "external",
        "mutability": "nonpayable", "parameters": ["uint256"], "returns": [],
        "modifiers": ["nonReentrant", "whenNotPaused"],
        "anchors": [("branch", "if"), ("call", "activeSourceRemaining"), ("return", "return"),
                    ("loop", "while"), ("call", "_startUnwind"), ("write", "next"),
                    ("write", "maxRequests"), ("write", "queueUnwind")],
    },
    {
        "source": "src/CollateralVault.sol", "contract": "CollateralVault", "function": "pokeSettle",
        "selector": "e891ab49", "semantic": "vaultPokeSettle", "visibility": "external",
        "mutability": "nonpayable", "parameters": [], "returns": ["uint256"],
        "modifiers": ["nonReentrant"],
        "anchors": [("call", "pullFreed"), ("call", "creditSource"), ("write", "deleverTarget"),
                    ("branch", "if"), ("call", "_repayMain"), ("loop", "while"),
                    ("emit", "RedeemSettled"), ("write", "queueHead"),
                    ("call", "_coverRounding"), ("call", "_refreshDiscount"), ("write", "work")],
    },
)


class BodyError(ValueError):
    pass


FORBIDDEN_BODY_NODES = {
    "InlineAssembly", "YulBlock", "YulFunctionCall", "YulAssignment", "UncheckedBlock",
    "TryStatement", "PlaceholderStatement",
}


def all_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from all_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_nodes(child)


def _type_strings(parameters):
    return [item.get("typeDescriptions", {}).get("typeString") for item in parameters.get("parameters", [])]


def _modifier_names(function):
    names = []
    for modifier in function.get("modifiers", []):
        name = modifier.get("modifierName", {})
        names.append(name.get("name") or name.get("namePath") or name.get("memberName"))
        require(name.get("referencedDeclaration") is not None, "modifier is not declaration-bound")
        require(not modifier.get("arguments"), "modifier arguments are outside the stateful body binding")
    return names


def _call_name(node):
    expression_node = node.get("expression", {})
    while expression_node.get("nodeType") == "FunctionCallOptions":
        expression_node = expression_node.get("expression", {})
    tag = expression_node.get("nodeType")
    if tag == "Identifier":
        return expression_node.get("name", "?")
    if tag == "MemberAccess":
        return expression_node.get("memberName", "?")
    if tag == "ElementaryTypeNameExpression":
        return expression_node.get("typeName", {}).get("name", "conversion")
    return tag or "?"


def _write_name(node):
    tag = node.get("nodeType")
    if tag == "Identifier":
        return node.get("name", "?")
    if tag == "MemberAccess":
        return node.get("memberName", "?")
    if tag == "IndexAccess":
        return _write_name(node.get("baseExpression", {})) + "[]"
    if tag == "TupleExpression":
        return ",".join(_write_name(part) for part in node.get("components", []) if part is not None)
    return tag or "?"


def body_trace(body):
    trace = []

    def add(kind, label, depth):
        trace.append((kind, label, depth))

    def walk_expression(node, depth):
        if not isinstance(node, dict):
            return
        tag = node.get("nodeType")
        if tag == "FunctionCall":
            add("call", _call_name(node), depth)
        elif tag == "Assignment":
            add("write", _write_name(node.get("leftHandSide", {})), depth)
        elif tag == "UnaryOperation" and node.get("operator") in ("++", "--", "delete"):
            add("write", _write_name(node.get("subExpression", {})), depth)
        for key, child in node.items():
            if key in {"typeDescriptions", "documentation"}:
                continue
            if isinstance(child, dict):
                walk_expression(child, depth)
            elif isinstance(child, list):
                for item in child:
                    if isinstance(item, dict):
                        walk_expression(item, depth)

    def walk_statement(node, depth=0):
        tag = node.get("nodeType")
        if tag == "Block":
            add("block", "begin", depth)
            for statement in node.get("statements", []):
                walk_statement(statement, depth + 1)
            add("block", "end", depth)
        elif tag == "VariableDeclarationStatement":
            names = ",".join(item.get("name", "_") for item in node.get("declarations", []) if item)
            add("bind", names, depth)
            walk_expression(node.get("initialValue"), depth)
        elif tag == "ExpressionStatement":
            walk_expression(node.get("expression"), depth)
        elif tag == "IfStatement":
            add("branch", "if", depth)
            walk_expression(node.get("condition"), depth)
            walk_statement(node["trueBody"], depth + 1)
            if node.get("falseBody") is not None:
                walk_statement(node["falseBody"], depth + 1)
        elif tag in ("WhileStatement", "DoWhileStatement", "ForStatement"):
            add("loop", {"WhileStatement": "while", "DoWhileStatement": "doWhile",
                         "ForStatement": "for"}[tag], depth)
            for key in ("initializationExpression", "condition", "loopExpression"):
                child = node.get(key)
                if isinstance(child, dict) and child.get("nodeType", "").endswith("Statement"):
                    walk_statement(child, depth + 1)
                else:
                    walk_expression(child, depth)
            walk_statement(node["body"], depth + 1)
        elif tag == "EmitStatement":
            call = node.get("eventCall", {})
            add("emit", _call_name(call), depth)
            for argument in call.get("arguments", []):
                walk_expression(argument, depth)
        elif tag == "RevertStatement":
            call = node.get("errorCall", {})
            add("revert", _call_name(call), depth)
            for argument in call.get("arguments", []):
                walk_expression(argument, depth)
        elif tag == "Return":
            add("return", "return", depth)
            walk_expression(node.get("expression"), depth)
        elif tag in ("Break", "Continue"):
            add(tag.lower(), tag.lower(), depth)
        else:
            raise BodyError(f"unsupported stateful statement node: {tag}")

    walk_statement(body)
    return trace


def _normalized_ast(value):
    ignored = {"id", "src", "scope", "nameLocation", "documentation"}
    if isinstance(value, dict):
        return {key: _normalized_ast(child) for key, child in sorted(value.items()) if key not in ignored}
    if isinstance(value, list):
        return [_normalized_ast(child) for child in value]
    return value


def _stateful_function(artifact, target):
    ast = artifact.get("ast", {})
    require(ast.get("nodeType") == "SourceUnit" and ast.get("absolutePath") == target["source"],
            f"wrong source AST for {target['contract']}.{target['function']}")
    contracts = [node for node in ast.get("nodes", [])
                 if node.get("nodeType") == "ContractDefinition" and node.get("name") == target["contract"]]
    require(len(contracts) == 1, f"missing or ambiguous contract {target['contract']}")
    functions = [node for node in contracts[0].get("nodes", [])
                 if node.get("nodeType") == "FunctionDefinition" and node.get("name") == target["function"]
                 and _type_strings(node.get("parameters", {})) == target["parameters"]]
    require(len(functions) == 1, f"missing or ambiguous function {target['contract']}.{target['function']}")
    return functions[0]


def stateful_body(function, target):
    require(function.get("implemented") is True and function.get("kind") == "function",
            "expected implemented stateful function")
    require(function.get("visibility") == target["visibility"] and
            function.get("stateMutability") == target["mutability"], "stateful signature changed")
    require(_type_strings(function.get("parameters", {})) == target["parameters"], "parameter types changed")
    require(_type_strings(function.get("returnParameters", {})) == target["returns"], "return types changed")
    require(function.get("functionSelector") == target["selector"], "function selector changed")
    require(_modifier_names(function) == target["modifiers"], "modifier prefix changed")
    require(not function.get("virtual") and not function.get("overrides"), "override dispatch is outside binding")
    body = function.get("body", {})
    require(body.get("nodeType") == "Block", "expected checked function block")
    forbidden = sorted({node.get("nodeType") for node in all_nodes(body)
                        if node.get("nodeType") in FORBIDDEN_BODY_NODES})
    require(not forbidden, f"unsupported opaque body nodes: {forbidden}")
    trace = body_trace(body)
    cursor = 0
    flattened = [(kind, label) for kind, label, _ in trace]
    for anchor in target["anchors"]:
        try:
            cursor = flattened.index(anchor, cursor) + 1
        except ValueError as error:
            raise BodyError(f"missing ordered semantic anchor {anchor} in {target['function']}") from error
    encoded = json.dumps(_normalized_ast(body), sort_keys=True, separators=(",", ":"))
    return {
        "trace": trace,
        "digest": hashlib.sha256(encoded.encode()).hexdigest(),
        "statementCount": sum(1 for kind, _, _ in trace if kind in {
            "bind", "branch", "loop", "emit", "revert", "return", "break", "continue"}),
    }


def require(condition, message):
    if not condition:
        raise BodyError(message)


def scalar_kind(description):
    if description == {"typeIdentifier": "t_uint256", "typeString": "uint256"}:
        return "word"
    if description == {"typeIdentifier": "t_bool", "typeString": "bool"}:
        return "boolean"
    raise BodyError(f"unsupported expression type: {description}")


def expression(node, parameters):
    tag = node.get("nodeType")
    if tag == "Literal":
        value = node.get("value", "")
        require(node.get("kind") == "number" and re.fullmatch(r"[0-9]+", value), "unsupported literal")
        number = int(value)
        require(number < 2**256 and not node.get("subdenomination"), "literal outside uint256")
        require(node.get("typeDescriptions") == {
            "typeIdentifier": f"t_rational_{number}_by_1", "typeString": f"int_const {number}"
        }, "unsupported literal type")
        return "word", f"(.literal {number})"
    kind = scalar_kind(node.get("typeDescriptions"))
    if tag == "Identifier":
        declaration = node.get("referencedDeclaration")
        require(kind == "word" and declaration in parameters, "identifier is not a uint256 parameter")
        require(not node.get("overloadedDeclarations"), "overloaded identifier")
        return kind, f"(.parameter {parameters[declaration]})"
    if tag == "TupleExpression":
        parts = node.get("components", [])
        require(not node.get("isInlineArray") and len(parts) == 1 and parts[0] is not None,
                "unsupported tuple expression")
        inner_kind, term = expression(parts[0], parameters)
        require(inner_kind == kind, "parenthesized expression type changed")
        return kind, term
    if tag == "BinaryOperation":
        operator = node.get("operator")
        constructors = {"+": "add", "-": "sub", ">>": "shr", "==": "eq"}
        require(operator in constructors and not node.get("function"), "unsupported binary operator")
        require(scalar_kind(node.get("commonType")) == "word", "non-uint256 binary operation")
        left_kind, left = expression(node["leftExpression"], parameters)
        right_kind, right = expression(node["rightExpression"], parameters)
        require(left_kind == right_kind == "word", "non-word operand")
        require(kind == ("boolean" if operator == "==" else "word"), "binary result type changed")
        return kind, f"(.{constructors[operator]} {left} {right})"
    if tag == "Conditional":
        condition_kind, condition = expression(node["condition"], parameters)
        yes_kind, yes = expression(node["trueExpression"], parameters)
        no_kind, no = expression(node["falseExpression"], parameters)
        require(condition_kind == "boolean" and yes_kind == no_kind == kind, "conditional type mismatch")
        return kind, f"(.choose {condition} {yes} {no})"
    raise BodyError(f"unsupported expression node: {tag}")


def function_body(function):
    require(function.get("nodeType") == "FunctionDefinition" and function.get("kind") == "function"
            and function.get("implemented") is True, "expected implemented function")
    require(function.get("stateMutability") == "pure" and function.get("visibility") == "private",
            "expected private pure body")
    require(not function.get("modifiers") and not function.get("virtual") and not function.get("overrides"),
            "modifiers or override dispatch are outside the expression semantics")
    arguments = function.get("parameters", {}).get("parameters", [])
    require(len(arguments) == 2, "expected two parameters")
    for argument in arguments:
        require(argument.get("nodeType") == "VariableDeclaration" and not argument.get("stateVariable")
                and argument.get("storageLocation") == "default"
                and scalar_kind(argument.get("typeDescriptions")) == "word", "unsupported parameter")
    parameters = {argument["id"]: index for index, argument in enumerate(arguments)}
    require(len(parameters) == len(arguments), "duplicate parameter declaration")
    returns = function.get("returnParameters", {})
    outputs = returns.get("parameters", [])
    require(len(outputs) == 1 and scalar_kind(outputs[0].get("typeDescriptions")) == "word",
            "expected uint256 return")
    body = function.get("body", {})
    statements = body.get("statements", [])
    require(body.get("nodeType") == "Block" and len(statements) == 1,
            "expected a checked block containing one return")
    statement = statements[0]
    require(statement.get("nodeType") == "Return" and statement.get("functionReturnParameters") == returns.get("id"),
            "unsupported statement or return binding")
    kind, term = expression(statement["expression"], parameters)
    require(kind == "word", "return expression is not uint256")
    return term


def selected_function(artifact):
    ast = artifact.get("ast", {})
    require(ast.get("nodeType") == "SourceUnit" and ast.get("absolutePath") == SOURCE, "wrong source AST")
    contracts = [node for node in ast.get("nodes", [])
                 if node.get("nodeType") == "ContractDefinition" and node.get("name") == CONTRACT]
    require(len(contracts) == 1, "missing or ambiguous contract")
    functions = [node for node in contracts[0].get("nodes", [])
                 if node.get("nodeType") == "FunctionDefinition" and node.get("name") == FUNCTION]
    require(len(functions) == 1, "missing or ambiguous function")
    return functions[0]


def _lean_string(value):
    return json.dumps(value)


def generated_module(artifact, stateful=()):
    term = function_body(selected_function(artifact))
    output = ("import JuicerLean.Solidity.Bodies\n\nnamespace Juicer.Solidity\n\n"
              "def accountingShiftIndex : Expr .word :=\n  " + term + "\n")
    for target, checked in stateful:
        steps = ",\n    ".join(
            f"⟨.{kind}, {_lean_string(label)}, {depth}⟩" for kind, label, depth in checked["trace"])
        output += (f"\ndef {target['semantic']}Body : BodyBinding := {{\n"
                   f"  semantic := .{target['semantic']}\n"
                   f"  contract := .{'vault' if target['contract'] == 'CollateralVault' else 'accounting'}\n"
                   f"  selector := 0x{target['selector']}\n"
                   f"  source := {_lean_string(target['source'])}\n"
                   f"  functionName := {_lean_string(target['function'])}\n"
                   f"  astSha256 := {_lean_string(checked['digest'])}\n"
                   f"  parameterCount := {len(target['parameters'])}\n"
                   f"  returnCount := {len(target['returns'])}\n"
                   f"  statementCount := {checked['statementCount']}\n"
                   f"  trace := [\n    {steps}\n  ]\n"
                   "}\n")
    return output + "\nend Juicer.Solidity\n"


def build(vault, artifacts):
    environment = compiler_environment("ast-cache")
    subprocess.run(["forge", "build", "--offline", "--skip", "test", "--skip", "script", "--ast",
                    "--out", str(artifacts), "--cache-path", str(compiler_cache_path("ast-cache"))],
                   cwd=vault, env=environment, stdout=sys.stderr, check=True)


def main():
    parser = argparse.ArgumentParser(description="check selected solc bodies against generated Lean expressions")
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--emit", action="store_true")
    args = parser.parse_args()
    formal = Path(__file__).resolve().parent
    vault = formal.parent
    artifacts = args.artifacts.resolve() if args.artifacts else formal / ".stateful/ast-out"
    if args.artifacts is None:
        build(vault, artifacts)
    artifact = json.loads((artifacts / f"{CONTRACT}.sol" / f"{CONTRACT}.json").read_text())
    expected = json.loads((formal / "bytecode-manifest.json").read_text())["contracts"][CONTRACT]
    require(artifact.get("metadata", {}).get("compiler", {}).get("version") == expected["summary"]["compiler"],
            "unreviewed compiler version")
    checked_stateful = []
    artifacts_by_contract = {CONTRACT: artifact}
    for target in STATEFUL_TARGETS:
        target_artifact = artifacts_by_contract.get(target["contract"])
        if target_artifact is None:
            target_artifact = json.loads((artifacts / f"{target['contract']}.sol" /
                                          f"{target['contract']}.json").read_text())
            artifacts_by_contract[target["contract"]] = target_artifact
        require(target_artifact.get("metadata", {}).get("compiler", {}).get("version") ==
                expected["summary"]["compiler"], "unreviewed compiler version")
        checked_stateful.append((target, stateful_body(_stateful_function(target_artifact, target), target)))
    generated = generated_module(artifact, checked_stateful)
    if args.emit:
        print(generated, end="")
        return
    manifest = json.loads((formal / "solidity-manifest.json").read_text())
    require(hashlib.sha256((vault / SOURCE).read_bytes()).hexdigest() == manifest["files"][SOURCE],
            "source changed; review the body proof and source manifest")
    require(generated == (formal / "JuicerLean/Solidity/GeneratedBodies.lean").read_text(),
            "Solidity body changed; regenerate the expression and reprove correspondence")
    subprocess.run(["python3", str(formal / "check-bytecode.py"), "--artifacts", str(artifacts)], check=True)
    names = ", ".join(f"{target['contract']}.{target['function']}" for target, _ in checked_stateful)
    print(f"solc body extraction matches: JuicerYieldAccounting._shiftIndex; {names}")


if __name__ == "__main__":
    try:
        main()
    except (BodyError, KeyError, TypeError) as error:
        raise SystemExit(f"Solidity body check failed: {error}") from error
