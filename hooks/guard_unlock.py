from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

MAX_SECONDS = 12 * 60 * 60


def state_directory() -> Path:
    return Path.home() / ".local" / "state" / "meridian-guard"


def grant_path() -> Path:
    return state_directory() / "grant.json"


def _private(path: Path, directory: bool = False) -> bool:
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    return kind(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077


def active_expiry() -> int | None:
    try:
        if not _private(state_directory(), True) or not _private(grant_path()):
            return None
        payload = json.loads(grant_path().read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or set(payload) != {"expires_at"}:
            return None
        expiry = payload["expires_at"]
        now = time.time()
        if type(expiry) is int and now < expiry <= now + MAX_SECONDS:
            return expiry
    except (OSError, ValueError, RuntimeError):
        return None
    return None


def expiry_message(expiry: int) -> str:
    stamp = datetime.fromtimestamp(expiry, timezone.utc).isoformat()
    return f"Meridian guard source unlock active until {stamp}."


def _duration(value: str) -> int:
    match = re.fullmatch(r"([1-9][0-9]*)([mh])", value)
    if match:
        seconds = int(match[1]) * (60 if match[2] == "m" else 3600)
        if seconds <= MAX_SECONDS:
            return seconds
    raise argparse.ArgumentTypeError("Use a duration in m or h, at most 12h.")


def _allow(seconds: int) -> None:
    directory = state_directory()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not _private(directory, True):
        raise ValueError("Guard state directory must be private and owned by this user.")
    expiry = int(time.time()) + seconds
    descriptor, temporary = tempfile.mkstemp(prefix=".grant-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"expires_at": expiry}, stream)
        os.replace(temporary, grant_path())
    finally:
        Path(temporary).unlink(missing_ok=True)
    print(expiry_message(expiry))


def _revoke() -> None:
    if state_directory().exists() and not _private(state_directory(), True):
        raise ValueError("Guard state directory must be private and owned by this user.")
    grant_path().unlink(missing_ok=True)
    print("Meridian guard source unlock revoked.")


def _execute(arguments: argparse.Namespace) -> None:
    if arguments.action == "allow":
        _allow(arguments.seconds)
        return
    if arguments.action == "revoke":
        _revoke()
        return
    if arguments.action == "session-status":
        expiry = active_expiry()
        if expiry:
            print(expiry_message(expiry))
        return
    if arguments.action == "status":
        expiry = active_expiry()
        print(expiry_message(expiry) if expiry else "Meridian guard source unlock inactive.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Owner control for Meridian guard source edits.")
    actions = parser.add_subparsers(dest="action", required=True)
    allow = actions.add_parser("allow")
    allow.add_argument("--for", dest="seconds", type=_duration, required=True)
    actions.add_parser("revoke")
    actions.add_parser("status")
    actions.add_parser("session-status")
    arguments = parser.parse_args()
    try:
        _execute(arguments)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
