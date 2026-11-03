from contextlib import contextmanager
import functools
import json
import os
from pathlib import Path
import subprocess
import time
from typing import Callable, Iterator


HELPER = Path(__file__).resolve().parent.parent / "scripts/lib/debug-logging.sh"
_CONFIGURATION = None
_DISPATCHED = False


@contextmanager
def dispatched_decisions() -> Iterator[None]:
    global _DISPATCHED
    previous, _DISPATCHED = _DISPATCHED, True
    try:
        yield
    finally:
        _DISPATCHED = previous


def _configuration(cwd):
    global _CONFIGURATION
    if _CONFIGURATION is None:
        _CONFIGURATION = (False, "")
        try:
            result = subprocess.run(
                ["bash", "-c", '. "$1"; debug_logging_init "$2"; '
                 'printf "%s\\0%s" "${DEBUG_LOGGING_ENABLED:-false}" "${DEBUG_LOGGING_DIR:-}"',
                 "debug-logging", str(HELPER), cwd],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2,
            )
            enabled, directory = os.fsdecode(result.stdout).split("\0", 1)
            _CONFIGURATION = (enabled == "true", directory)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    return _CONFIGURATION


class DebugLogger:
    def __init__(self, text=""):
        self.enabled, self.directory = False, ""
        self.component, self.event = "gate", "unknown"
        try:
            data = json.loads(text) if text else {}
            cwd = data.get("cwd", "") if isinstance(data, dict) else ""
            self.enabled, self.directory = _configuration(cwd if isinstance(cwd, str) else "")
        except (OSError, ValueError):
            pass

    def log(self, check, outcome) -> None:
        if not self.enabled:
            return
        decision, reason, started = outcome
        duration = "unknown" if started is None else str(round((time.monotonic() - started) * 1000))
        try:
            subprocess.run(
                ["bash", "-c", '. "$1"; DEBUG_LOGGING_ENABLED=true; DEBUG_LOGGING_DIR="$2"; '
                 'shift 2; debug_logging_append "$@"', "debug-logging", str(HELPER),
                 self.directory, self.component, self.event, check, decision, duration, reason],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1,
            )
        except (OSError, subprocess.SubprocessError):
            pass


def trace_decision(function) -> Callable:
    @functools.wraps(function)
    def traced(text, *args, **kwargs) -> object:
        if _DISPATCHED:
            return function(text, *args, **kwargs)
        logger = DebugLogger(text)
        mode = args[0] if function.__name__ == "_dispatch" and args else "pretool"
        logger.event = {"pretool": "PreToolUse", "posttool": "PostToolUse",
                        "prompt": "UserPromptSubmit", "stop": "Stop"}.get(mode, "unknown")
        check = function.__module__.rsplit(".", 1)[-1]
        if check == "__main__":
            check = Path(function.__code__.co_filename).stem
        started = time.monotonic()
        try:
            result = function(text, *args, **kwargs)
        except Exception:
            logger.log(check, ("error", "exception", started))
            raise
        logger.log(check, ("deny" if result is not None else "allow",
                           "blocked" if result is not None else "completed", started))
        return result
    return traced


def result_decision(status, output) -> tuple[str, str]:
    if status == 124:
        return "timeout", "deadline"
    if status == 2:
        return "deny", "blocked"
    if status != 0:
        return "error", "nonzero"
    if not output.strip():
        return "allow", "completed"
    try:
        value = json.loads(output)
        specific = value.get("hookSpecificOutput", {})
        if specific.get("permissionDecision") == "deny" or value.get("decision") == "block":
            return "deny", "blocked"
        if specific.get("additionalContext") or value.get("systemMessage"):
            return "warn", "advisory"
    except (ValueError, AttributeError):
        return "warn", "invalid_output"
    return "allow", "completed"
