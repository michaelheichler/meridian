#!/usr/bin/env python3
from __future__ import annotations

import argparse, fcntl, hashlib, json, math, os, sys, time
from datetime import datetime, timezone
from pathlib import Path

EVENTS = {"session_start", "session_stop", "phase_start", "phase_end", "command", "tool_call"}
OUTCOMES = {"success", "failure", "partial", "blocked"}
FIELDS = {"ts", "session_id", "actor", "event", "outcome", "duration_ms", "tokens_in", "tokens_out", "model", "phase", "prev_sha256", "sha256"}
RAW = {"transcript", "prompt", "tool", "tool_input", "tool_output", "payload", "content", "message"}
MAX_VALUE = 256
MAX_LINE = 4096
LOCK_TIMEOUT = 0.25

class TelemetryError(Exception): pass

def migrate_environment() -> None:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "hooks"))
    from rename_migration import migrate_environment as migrate
    migrate()

def planning_root(raw: str | None = None) -> Path:
    migrate_environment()
    value = raw or os.environ.get("MERIDIAN_PLANNING_DIR", ".meridian")
    if not value or "\x00" in value:
        raise TelemetryError("invalid planning root")
    return Path(value).expanduser().resolve()

def target(root: str | None = None) -> Path:
    return planning_root(root) / "telemetry" / "session.jsonl"

def digest(record: dict) -> str:
    body = {key: value for key, value in record.items() if key != "sha256"}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def validate(record: dict, *, chain_prev=None) -> None:
    if not isinstance(record, dict) or set(record) - FIELDS or FIELDS - set(record):
        raise TelemetryError("record schema rejected")
    if any(key in record for key in RAW): raise TelemetryError("raw payload key rejected")
    if record.get("actor") != "main": raise TelemetryError("actor must be main")
    if record.get("event") not in EVENTS: raise TelemetryError("invalid event")
    if record.get("outcome") not in OUTCOMES: raise TelemetryError("invalid outcome")
    if chain_prev is not None and record.get("prev_sha256") != chain_prev: raise TelemetryError("hash chain mismatch")
    if digest(record) != record.get("sha256"): raise TelemetryError("sha256 mismatch")
    for key, value in record.items():
        if isinstance(value, str) and len(value) > MAX_VALUE: raise TelemetryError("value exceeds limit")
    duration = record.get("duration_ms")
    if duration is not None and (not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(duration) or duration < 0): raise TelemetryError("invalid duration")

def parse_record(line: str, line_number: int, previous: str | None) -> dict:
    if len(line.encode()) > MAX_LINE:
        raise TelemetryError(f"record line {line_number} exceeds limit")
    try: record = json.loads(line)
    except json.JSONDecodeError as error:
        raise TelemetryError(f"malformed prior record at line {line_number}") from error
    validate(record, chain_prev=previous)
    if previous is None and record.get("prev_sha256") is not None:
        raise TelemetryError(f"genesis record at line {line_number} must have null prev_sha256")
    return record

def read_chain(path: Path) -> list[dict]:
    if not path.exists(): return []
    rows = []
    previous = None
    with path.open(encoding="utf-8") as source:
        lines = ((number, line) for number, line in enumerate(source, 1) if line.strip())
        for line_number, line in lines:
            record = parse_record(line, line_number, previous)
            previous = record["sha256"]
            rows.append(record)
    return rows

def lock_ready(descriptor: int) -> bool:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False

def acquire(descriptor: int) -> None:
    migrate_environment()
    try: configured = float(os.environ.get("MERIDIAN_TELEMETRY_LOCK_TIMEOUT", LOCK_TIMEOUT))
    except ValueError: configured = LOCK_TIMEOUT
    if not math.isfinite(configured): configured = LOCK_TIMEOUT
    deadline = time.monotonic() + min(max(configured, 0.0), 1.0)
    while not lock_ready(descriptor):
        if time.monotonic() >= deadline: raise TelemetryError("timed out waiting for telemetry lock")
        time.sleep(.01)

def record(args) -> int:
    path = target(args.root)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        acquire(descriptor)
        rows = read_chain(path)
        previous = rows[-1]["sha256"] if rows else None
        entry = {"ts":datetime.now(timezone.utc).isoformat(), "session_id":args.session_id, "actor":"main", "event":args.event, "outcome":args.outcome, "duration_ms":args.duration_ms, "tokens_in":args.tokens_in, "tokens_out":args.tokens_out, "model":args.model, "phase":args.phase, "prev_sha256":previous}
        entry["sha256"] = digest(entry)
        encoded = json.dumps(entry, sort_keys=True, separators=(",", ":"))
        validate(entry, chain_prev=previous)
        if len(encoded.encode()) > MAX_LINE: raise TelemetryError("record exceeds size limit")
        with os.fdopen(descriptor, "a", closefd=False) as output:
            output.write(encoded + "\n")
            output.flush()
            os.fsync(output.fileno())
        print(entry["sha256"])
        return 0
    except (TelemetryError, ValueError, OSError) as error:
        print(f"telemetry: {error}", file=sys.stderr)
        return 2
    finally: os.close(descriptor)

def percentile(durations: list, fraction: float) -> float | None:
    if not durations: return None
    return durations[min(len(durations)-1, max(0, math.ceil(fraction*len(durations))-1))]

def report(args) -> int:
    try: rows = read_chain(target(args.root))
    except TelemetryError as error:
        print(f"telemetry: tamper detected: {error}")
        return 2
    durations = sorted(entry["duration_ms"] for entry in rows if isinstance(entry.get("duration_ms"), (int,float)))
    counts = {"events":{}, "outcomes":{}}
    for entry in rows:
        counts["events"][entry["event"]] = counts["events"].get(entry["event"],0)+1
        counts["outcomes"][entry["outcome"]] = counts["outcomes"].get(entry["outcome"],0)+1
    print(json.dumps({"total":len(rows), **counts, "p50_ms":percentile(durations,.5), "p95_ms":percentile(durations,.95)}, sort_keys=True, separators=(",", ":")))
    return 0

def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    recorder = subcommands.add_parser("record")
    recorder.add_argument("--event", required=True)
    recorder.add_argument("--outcome", required=True)
    recorder.add_argument("--duration-ms", type=float, default=None)
    recorder.add_argument("--tokens-in", type=int, default=None)
    recorder.add_argument("--tokens-out", type=int, default=None)
    recorder.add_argument("--model", default=None)
    recorder.add_argument("--phase", default=None)
    recorder.add_argument("--session-id", default=None)
    recorder.add_argument("--root")
    recorder.set_defaults(func=record)
    reporter = subcommands.add_parser("report")
    reporter.add_argument("--root")
    reporter.set_defaults(func=report)
    args = parser.parse_args(argv)
    if args.command == "record" and (args.event not in EVENTS or args.outcome not in OUTCOMES):
        print("telemetry: invalid enum", file=sys.stderr)
        return 2
    return args.func(args)

if __name__ == "__main__": raise SystemExit(main())
