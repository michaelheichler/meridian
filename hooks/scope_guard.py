import re
import sys

from debug_logging import trace_decision
from skill_gate import (
    INVALID_MANIFEST,
    InvalidManifest,
    _agent_identifier,
    _parse_pretool_input,
    _role_for_identifier,
    emit_pretool_denial,
)

ENGINEER_ROLES = {"coding-dijkstra", "python-engineer", "web-engineer"}
WRITE_TOOLS = ("Write", "Edit", "NotebookEdit")
TEST_PATH_PATTERN = re.compile(r"(^|/)tests?/")
TEST_FILENAME_PATTERN = re.compile(r"\.(test|spec)\.")


def _is_test_path(file_path: str) -> bool:
    if TEST_PATH_PATTERN.search(file_path):
        return True
    basename = file_path.rsplit("/", 1)[-1]
    return bool(TEST_FILENAME_PATTERN.search(basename))


def blocked() -> str:
    return ("The test directory belongs to your test-dev teammate. Hand the "
            "function off and let test-dev write the test, do not write it "
            "yourself.")


@trace_decision
def verdict(stdin_text, cwd=None) -> "str | None":
    data, error = _parse_pretool_input(stdin_text)
    if error:
        print(error, file=sys.stderr)
        return None
    assert data is not None
    tool_name = data.get("tool_name") or ""
    if tool_name not in WRITE_TOOLS:
        return None
    tool_input = data["tool_input"]
    paths = (tool_input.get("file_path"), tool_input.get("notebook_path"))
    if not any(isinstance(path, str) and _is_test_path(path) for path in paths):
        return None
    identifier = _agent_identifier(data)
    if not identifier:
        return None
    try:
        role = _role_for_identifier(identifier, cwd or data.get("cwd"))
    except InvalidManifest:
        return INVALID_MANIFEST
    if role not in ENGINEER_ROLES:
        return None
    return blocked()


def main() -> None:
    try:
        reason = verdict(sys.stdin.read())
    except Exception as exc:
        print(f"Hook warning: scope_guard crashed ({exc!r}), call allowed.", file=sys.stderr)
        sys.exit(0)
    if reason is None:
        sys.exit(0)
    emit_pretool_denial(reason)
    sys.exit(0)


if __name__ == "__main__":
    main()
