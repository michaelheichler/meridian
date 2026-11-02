"""Keep native context measurements because transcript size only approximates occupancy."""
import json
import os
import sys
import tempfile

CHARS_PER_TOKEN = 4
DEFAULT_CONTEXT_WINDOW = 200000
USAGE_FILENAME = ".context-usage"
RESET_FILENAME = ".context-usage-reset"


def _find_planning_dir(start):
    current = os.path.abspath(start or os.getcwd())
    while True:
        candidate = os.path.join(current, ".lbwc-planning")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def _context_window(planning_dir):
    config_path = os.path.join(planning_dir, "config.json")
    try:
        with open(config_path) as config_file:
            value = json.load(config_file).get("context_window_tokens")
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            return value
    except (OSError, ValueError, AttributeError):
        pass
    return DEFAULT_CONTEXT_WINDOW


def _read_record(path):
    try:
        with open(path) as record_file:
            return record_file.read().strip().split("|")
    except OSError:
        return []


def _native_record(path, session_id):
    fields = _read_record(path)
    if len(fields) != 4 or fields[0] != session_id or fields[3] != "statusline":
        return False
    try:
        return 0 <= float(fields[1]) <= 100 and int(fields[2]) > 0
    except ValueError:
        return False


def _write_record(path, record, session_id=None):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=os.path.dirname(path), delete=False) as output:
            temporary = output.name
            output.write(record + "\n")
        if session_id is not None and _native_record(path, session_id):
            return
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def _reset_usage(planning_dir, data):
    session_id = str(data.get("session_id") or "unknown")
    transcript = data.get("transcript_path") or ""
    try:
        baseline = os.path.getsize(transcript)
    except OSError:
        baseline = -1
    _write_record(os.path.join(planning_dir, RESET_FILENAME), f"{session_id}|{baseline}")
    usage_path = os.path.join(planning_dir, USAGE_FILENAME)
    if os.path.exists(usage_path):
        os.unlink(usage_path)


def _transcript_bytes(planning_dir, data):
    size = os.path.getsize(data.get("transcript_path") or "")
    reset = _read_record(os.path.join(planning_dir, RESET_FILENAME))
    if len(reset) == 2 and reset[0] == str(data.get("session_id") or "unknown"):
        baseline = int(reset[1])
        if baseline < 0:
            return None
        return size if size < baseline else size - baseline
    return size


def _update_usage(planning_dir, data):
    session_id = str(data.get("session_id") or "unknown")
    usage_path = os.path.join(planning_dir, USAGE_FILENAME)
    if _native_record(usage_path, session_id):
        return
    size = _transcript_bytes(planning_dir, data)
    if size is None:
        return
    ctx_size = _context_window(planning_dir)
    used_pct = min(100, max(0, (size // CHARS_PER_TOKEN) * 100 // ctx_size))
    _write_record(usage_path, f"{session_id}|{used_pct}|{ctx_size}", session_id)


def run(stdin_text, reset=False) -> None:
    try:
        data = json.loads(stdin_text)
        if not isinstance(data, dict):
            return
        planning_dir = os.environ.get("LBWC_PLANNING_DIR") or _find_planning_dir(data.get("cwd"))
        if not planning_dir or not os.path.isdir(planning_dir):
            return
        if reset or data.get("source") == "compact":
            _reset_usage(planning_dir, data)
        else:
            _update_usage(planning_dir, data)
    except (OSError, ValueError, TypeError):
        return


def main() -> None:
    run(sys.stdin.read(), reset="--reset" in sys.argv[1:])


if __name__ == "__main__":
    main()
