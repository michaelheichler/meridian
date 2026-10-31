from __future__ import annotations

import os
import re
import shlex
import signal
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Iterator, NamedTuple, Optional

if __package__:
    from .brace_expansion import ExpansionTooComplex, expand_braces
    from .decision_common import INVALID_STATE, DecisionStateError, require
    from .path_identity import ProtectedIdentity, TooManyMatches, expand_glob
    from .read_only_command import is_plain_read_command
else:
    from brace_expansion import ExpansionTooComplex, expand_braces
    from decision_common import INVALID_STATE, DecisionStateError, require
    from path_identity import ProtectedIdentity, TooManyMatches, expand_glob
    from read_only_command import is_plain_read_command

OptionalPath = Optional[Path]
GUARD_MODULES = (
    "user_question_guard.py",
    "decision_common.py",
    "decision_layout.py",
    "decision_io.py",
    "decision_records.py",
    "decision_store.py",
    "question_validation.py",
    "guard_paths.py",
    "read_only_command.py",
    "brace_expansion.py",
    "path_identity.py",
)
SCRIPT_MARKERS = ("pending-decision.sh", *GUARD_MODULES)
RUNTIME_MARKERS = (".lbwc-planning/.runtime", ".runtime/decisions", ".hook-transitions")
PROTECTED_MARKERS = (*SCRIPT_MARKERS, *RUNTIME_MARKERS)
EXPANSION_CHARS = "$`*?[{"
UNRESOLVED_CHARS = "$`"
GLOB_CHARS = "*?["
SUFFIX_SPAN = 8
ANALYSIS_SECONDS = 3.5
TIMEOUT_REASON = "guard analysis timeout"
SEARCH_TOOLS = frozenset({"Grep", "Glob"})
SHELL_SPLIT = re.compile(r"[\s;&|<>()]+")
QUOTE_CHARS = "$'\""
FILES0_OPTION = "--files0-from"
FILES0_PREFIX = "--files0"
FILES0_COMMANDS = frozenset({"sort", "wc"})
FILES0_ABBREVIATION_FLOOR = 3
OPERATOR_SPLIT = re.compile(r"[<>&|;()]")
PLUGIN_ROOT = Path(__file__).resolve().parent.parent
PROTECTED_FILES = {
    (PLUGIN_ROOT / "scripts" / "pending-decision.sh").resolve(),
    *((PLUGIN_ROOT / "hooks" / name).resolve() for name in GUARD_MODULES),
}


class AnalysisTimeout(Exception):
    pass


class Scope(NamedTuple):
    identity: ProtectedIdentity
    markers: tuple[str, ...]


def _planning_candidate(directory: Path) -> OptionalPath:
    candidate = directory / ".lbwc-planning"
    if not (candidate.exists() or candidate.is_symlink()):
        return None
    require(candidate.is_dir() and not candidate.is_symlink(), INVALID_STATE)
    return candidate


def planning_directory(cwd: object) -> OptionalPath:
    if not isinstance(cwd, str) or not cwd:
        return None
    current = Path(cwd).resolve()
    while current != current.parent:
        found = _planning_candidate(current)
        if found is not None:
            return found
        current = current.parent
    return None


def current_directory(cwd: object) -> OptionalPath:
    return Path(cwd).resolve() if isinstance(cwd, str) and cwd else None


def _words(command: str) -> Optional[list[str]]:
    try:
        return shlex.split(command, comments=True)
    except ValueError:
        return None


def _has_expansion(word: str) -> bool:
    return any(char in word for char in EXPANSION_CHARS) or word.startswith("~")


def _has_glob(value: str) -> bool:
    return any(char in value for char in GLOB_CHARS)


def _candidates(word: str) -> set[str]:
    values = {word, *word.split("="), *OPERATOR_SPLIT.split(word)}
    if word.startswith("-"):
        values.update(word[index:] for index in range(1, min(len(word), SUFFIX_SPAN)))
    return {value for value in values if value}


def _operand_values(words: list[str]) -> list[str]:
    candidates = (value for word in words for value in _candidates(word))
    return [item for value in candidates for item in expand_braces(value)]


def _target(value: str, cwd: Path) -> Optional[str]:
    if any(char in value for char in UNRESOLVED_CHARS):
        return None
    return os.path.join(str(cwd), os.path.expanduser(value))


def _value_hit(value: str, cwd: Path, identity: ProtectedIdentity) -> bool:
    target = _target(value, cwd)
    if target is None:
        return False
    paths = [target]
    if _has_glob(value):
        if identity.glob_hits(target):
            return True
        paths = expand_glob(target)
    return any(identity.hits(path) for path in paths)


def _marker_hit(texts: Iterable[str], markers: tuple[str, ...]) -> bool:
    folded = [text.casefold() for text in texts]
    return any(marker.casefold() in text for marker in markers for text in folded)


def _direct_hit(tool_input: dict, cwd: OptionalPath, scope: Scope) -> bool:
    values = [tool_input.get("file_path"), tool_input.get("notebook_path")]
    texts = [value for value in values if isinstance(value, str)]
    if _marker_hit(texts, scope.markers):
        return True
    paths = [os.path.join(str(cwd), text) for text in texts] if cwd else []
    return any(scope.identity.hits(path) for path in paths)


def _fallback_words(command: str) -> list[str]:
    tokens = (token.strip(QUOTE_CHARS) for token in SHELL_SPLIT.split(command))
    return [token for token in tokens if token]


def _is_files0_option(word: str, floor: int) -> bool:
    name = word.split("=", 1)[0]
    return len(name) >= floor and FILES0_OPTION.startswith(name)


def _files0_hit(words: list[str]) -> bool:
    sorting = any(os.path.basename(word) in FILES0_COMMANDS for word in words)
    floor = FILES0_ABBREVIATION_FLOOR if sorting else len(FILES0_PREFIX)
    return any(_is_files0_option(word, floor) for word in words)


def _command_hit(command: str, cwd: OptionalPath, scope: Scope) -> bool:
    parsed = _words(command)
    words = _fallback_words(command) if parsed is None else parsed
    if _files0_hit(words):
        return True
    if _marker_hit((command, " ".join(words)), scope.markers):
        return True
    if cwd is None:
        return False
    values = _operand_values(words)
    return any(_value_hit(value, cwd, scope.identity) for value in values)


def _search_hit(data: dict, cwd: OptionalPath, identity: ProtectedIdentity) -> bool:
    tool_name = data.get("tool_name")
    if tool_name not in SEARCH_TOOLS or cwd is None:
        return False
    tool_input = data["tool_input"]
    base = tool_input.get("path")
    pattern = tool_input.get("pattern") if tool_name == "Glob" else None
    texts = [item for item in (base, pattern) if isinstance(item, str)]
    root = os.path.join(str(cwd), base) if isinstance(base, str) else str(cwd)
    scoped = identity.runtime_only()
    if _marker_hit(texts, RUNTIME_MARKERS) or scoped.hits(root):
        return True
    if not isinstance(pattern, str):
        return False
    return any(_value_hit(item, Path(root), scoped) for item in expand_braces(pattern))


def _read_exempt(command: str, cwd: OptionalPath) -> bool:
    words = _words(command)
    if cwd is None or words is None or any(_has_expansion(word) for word in words):
        return False
    return is_plain_read_command(command, str(cwd))


def _evaluate(data: dict, cwd: OptionalPath, full: Scope) -> bool:
    tool_input = data["tool_input"]
    if _direct_hit(tool_input, cwd, full) or _search_hit(data, cwd, full.identity):
        return True
    command = tool_input.get("command")
    if not isinstance(command, str):
        return False
    if data.get("tool_name") == "Bash" and _read_exempt(command, cwd):
        return _command_hit(command, cwd, Scope(full.identity.runtime_only(), RUNTIME_MARKERS))
    return _command_hit(command, cwd, full)


def _analyse(data: dict, planning_dir: OptionalPath) -> bool:
    identity = ProtectedIdentity.build(planning_dir, PROTECTED_FILES)
    cwd = current_directory(data.get("cwd"))
    return _evaluate(data, cwd, Scope(identity, PROTECTED_MARKERS))


@contextmanager
def _deadline(seconds: float) -> Iterator[None]:
    def expire(signum: int, frame: object) -> None:
        raise AnalysisTimeout()

    try:
        previous = signal.signal(signal.SIGALRM, expire)
    except (ValueError, AttributeError):
        yield
        return
    try:
        signal.setitimer(signal.ITIMER_REAL, seconds)
        yield
    finally:
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
        finally:
            signal.signal(signal.SIGALRM, previous)


def has_protected_decision_path(data: dict, planning_dir: OptionalPath) -> bool:
    if not isinstance(data.get("tool_input"), dict):
        return False
    try:
        with _deadline(ANALYSIS_SECONDS):
            return _analyse(data, planning_dir)
    except AnalysisTimeout:
        raise DecisionStateError(TIMEOUT_REASON) from None
    except (ExpansionTooComplex, TooManyMatches, ValueError):
        return True
