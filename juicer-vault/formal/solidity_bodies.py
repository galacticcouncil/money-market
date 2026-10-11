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


class BodyError(ValueError):
    pass


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


def generated_module(artifact):
    term = function_body(selected_function(artifact))
    return ("import JuicerLean.Solidity.Expressions\n\nnamespace Juicer.Solidity\n\n"
            "def accountingShiftIndex : Expr .word :=\n  " + term +
            "\n\nend Juicer.Solidity\n")


def build(vault, artifacts):
    environment = compiler_environment()
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
    generated = generated_module(artifact)
    if args.emit:
        print(generated, end="")
        return
    manifest = json.loads((formal / "solidity-manifest.json").read_text())
    require(hashlib.sha256((vault / SOURCE).read_bytes()).hexdigest() == manifest["files"][SOURCE],
            "source changed; review the body proof and source manifest")
    require(generated == (formal / "JuicerLean/Solidity/GeneratedBodies.lean").read_text(),
            "Solidity body changed; regenerate the expression and reprove correspondence")
    subprocess.run(["python3", str(formal / "check-bytecode.py"), "--artifacts", str(artifacts)], check=True)
    print("solc body extraction matches: JuicerYieldAccounting._shiftIndex")


if __name__ == "__main__":
    try:
        main()
    except (BodyError, KeyError, TypeError) as error:
        raise SystemExit(f"Solidity body check failed: {error}") from error
