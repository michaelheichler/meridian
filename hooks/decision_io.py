from __future__ import annotations

import json
import os
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, cast

if __package__:
    from .decision_common import DecisionStateError, INVALID_RECORD, require
else:
    from decision_common import DecisionStateError, INVALID_RECORD, require

LOCK_ATTEMPTS = 100
LOCK_DELAY_SECONDS = 0.01


def load_json(path: Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), INVALID_RECORD)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DecisionStateError(INVALID_RECORD) from error
    require(isinstance(payload, dict), INVALID_RECORD)
    return cast(dict[str, Any], payload)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".decision-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        os.close(descriptor)
        descriptor = -1
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        temporary_path.write_text(encoded, encoding="utf-8")
        temporary_path.replace(path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)


def _try_mkdir(path: Path) -> bool:
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        return False
    return True


def _acquire(lock_path: Path) -> None:
    for _ in range(LOCK_ATTEMPTS):
        if _try_mkdir(lock_path):
            return
        time.sleep(LOCK_DELAY_SECONDS)
    raise DecisionStateError("The pending user decision record is locked.")


@contextmanager
def record_lock(record_path: Path) -> Iterator[None]:
    lock_path = Path(f"{record_path}.lock")
    _acquire(lock_path)
    try:
        yield
    finally:
        lock_path.rmdir()
