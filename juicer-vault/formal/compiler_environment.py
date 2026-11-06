import json
import hashlib
import os
from pathlib import Path


def compiler_cache_path(name):
    formal = Path(__file__).resolve().parent
    digest = hashlib.sha256((formal / "compiler-remappings.json").read_bytes()).hexdigest()[:16]
    return formal / ".stateful" / f"{name}-{digest}"


def compiler_environment(cache_name="test-cache"):
    remappings = json.loads(Path(__file__).with_name("compiler-remappings.json").read_text())
    environment = os.environ.copy()
    environment.update(FOUNDRY_LIBS='["../bil-vault/lib","../node_modules"]',
                       FOUNDRY_AUTO_DETECT_REMAPPINGS="false",
                       FOUNDRY_REMAPPINGS="\n".join(remappings),
                       FOUNDRY_CACHE_PATH=str(compiler_cache_path(cache_name)))
    return environment
