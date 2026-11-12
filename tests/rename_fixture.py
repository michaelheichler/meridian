import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys


def entry(path: Path, root: Path) -> tuple:
    name = str(path.relative_to(root))
    if path.is_symlink():
        return name, "link", os.readlink(path)
    if path.is_file():
        return name, "file", hashlib.sha256(path.read_bytes()).hexdigest()
    return name, "directory"


def manifest(root: Path) -> None:
    entries = [entry(path, root) for path in sorted(root.rglob("*"))
               if ".git" not in path.relative_to(root).parts]
    print(json.dumps(entries, ensure_ascii=False))


def environment(module: str) -> None:
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("rename_migration", module)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    migration.migrate_environment()
    result = {name: value for name, value in os.environ.items()
              if name.startswith(("LBWC_TEST_", "MERIDIAN_TEST_"))}
    print(json.dumps(result, sort_keys=True, ensure_ascii=False))


if sys.argv[1] == "manifest":
    manifest(Path(sys.argv[2]))
elif sys.argv[1] == "environment":
    environment(sys.argv[2])
elif sys.argv[1] == "snapshot-environment":
    result = {name: value for name, value in os.environ.items()
              if name.startswith(("LBWC_TEST_", "MERIDIAN_TEST_"))}
    print(json.dumps(result, sort_keys=True, ensure_ascii=False))
