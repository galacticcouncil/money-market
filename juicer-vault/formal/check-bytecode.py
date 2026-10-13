#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from compiler_environment import compiler_environment, compiler_cache_path


def canonical_hash(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def code_summary(field, label):
    raw = field.get("object", "")
    if not raw.startswith("0x"):
        raise SystemExit(f"bytecode drift: {label} has no 0x prefix")
    try:
        code = bytes.fromhex(raw[2:])
    except ValueError as error:
        raise SystemExit(f"bytecode drift: {label} is not fully linked hex") from error
    return {
        "bytes": len(code),
        "sha256": hashlib.sha256(code).hexdigest(),
        "linkReferencesSha256": canonical_hash(field.get("linkReferences", {})),
        "immutableReferencesSha256": canonical_hash(field.get("immutableReferences", {})),
    }


def artifact_summary(path, source, contract):
    artifact = json.loads(path.read_text())
    metadata = artifact.get("metadata", {})
    settings = metadata.get("settings", {})
    target = settings.get("compilationTarget", {})
    if target != {source: contract}:
        raise SystemExit(f"bytecode drift: unexpected compilation target in {path}")
    methods = artifact.get("methodIdentifiers", {})
    return {
        "compiler": metadata.get("compiler", {}).get("version"),
        "optimizer": settings.get("optimizer"),
        "evmVersion": settings.get("evmVersion"),
        "viaIR": settings.get("viaIR"),
        "settingsSha256": canonical_hash(settings),
        "creation": code_summary(artifact.get("bytecode", {}), f"{contract} creation"),
        "runtimeTemplate": code_summary(
            artifact.get("deployedBytecode", {}), f"{contract} runtime template"
        ),
        "methodCount": len(methods),
        "methodIdentifiersSha256": canonical_hash(methods),
    }, methods


def build(vault, formal, artifacts):
    env = compiler_environment("bytecode-cache")
    subprocess.run(
        [
            "forge", "build", "--offline", "--skip", "test", "--skip", "script",
            "--out", str(artifacts), "--cache-path", str(compiler_cache_path("bytecode-cache")),
        ],
        cwd=vault,
        env=env,
        check=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    formal = Path(__file__).resolve().parent
    vault = formal.parent
    manifest = json.loads((formal / "bytecode-manifest.json").read_text())
    artifacts = args.artifacts or formal / ".stateful/bytecode-out"
    if args.artifacts is None:
        build(vault, formal, artifacts)

    actual = {}
    for name, expected in manifest["contracts"].items():
        path = artifacts / expected["artifact"]
        if not path.is_file():
            raise SystemExit(f"bytecode drift: missing artifact {path}")
        summary, methods = artifact_summary(path, expected["source"], name)
        required = expected.get("dispatchMethods", {})
        missing = {
            signature: selector
            for signature, selector in required.items()
            if methods.get(signature) != selector
        }
        if missing:
            raise SystemExit(f"bytecode drift: {name} dispatch selectors differ: {missing}")
        actual[name] = summary

    expected_summaries = {
        name: entry["summary"] for name, entry in manifest["contracts"].items()
    }
    if actual != expected_summaries:
        for name in actual:
            if actual[name] != expected_summaries.get(name):
                raise SystemExit(
                    f"bytecode drift: {name} artifact differs; review the compiler output "
                    "before updating formal/bytecode-manifest.json"
                )
        raise SystemExit("bytecode drift: contract set differs")

    print(
        f"compiled artifact binding passed: {len(actual)} production contracts, "
        f"{sum(row['methodCount'] for row in actual.values())} selectors"
    )


if __name__ == "__main__":
    main()
