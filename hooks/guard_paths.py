from __future__ import annotations

import glob
import os
import re
import shlex
import signal
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Iterator, NamedTuple, Optional

if __package__:
    from .brace_expansion import ExpansionTooComplex, expand_braces
    from .decision_common import INVALID_STATE, DecisionStateError, require
    from .path_identity import ProtectedIdentity, TooManyMatches, expand_glob
    from .read_only_command import command_segments, is_git_inspection, is_source_inspection
    from .guard_unlock import active_expiry, state_directory
else:
    from brace_expansion import ExpansionTooComplex, expand_braces
    from decision_common import INVALID_STATE, DecisionStateError, require
    from path_identity import ProtectedIdentity, TooManyMatches, expand_glob
    from read_only_command import command_segments, is_git_inspection, is_source_inspection
    from guard_unlock import active_expiry, state_directory

OptionalPath = Optional[Path]
GUARD_MODULES = (
    "dispatch.py",
    "hook_batch.py",
    "hook_output.py",
    "scope_guard.py",
    "skill_gate.py",
    "message_scope_guard.py",
    "tmux_git_policy.py",
    "tmux_restrictions.py",
    "context_usage.py",
    "rename_migration.py",
    "debug_logging.py",
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
SCRIPT_MARKERS = ("pending-decision.sh", "hook-batch.sh", *GUARD_MODULES)
RUNTIME_MARKERS = (".meridian/.runtime", ".runtime/decisions", ".hook-transitions")
PROTECTED_MARKERS = (
    *SCRIPT_MARKERS, *RUNTIME_MARKERS, "hooks.json", "__init__.py",
    "guard_unlock.py", "meridian-guard.sh", "session-start.sh",
)
EXPANSION_CHARS = "$`{"
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


class AnalysisTimeout(Exception):
    pass


class Scope(NamedTuple):
    identity: ProtectedIdentity
    markers: tuple[str, ...]


def _planning_candidate(directory: Path) -> OptionalPath:
    candidate = directory / ".meridian"
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


def _inspection_words(command: str, cwd: OptionalPath) -> Optional[list[str]]:
    words = _words(command)
    if not words or cwd is None or re.search(r"[#\n\r;&|<>()$`{]", command):
        return words
    inspection = is_git_inspection(words) if words[0] == "git" else is_source_inspection(command, str(cwd))
    if not inspection:
        return words
    lexer = shlex.shlex(command, posix=False)
    lexer.whitespace_split = True
    try:
        quoted = list(lexer)
    except ValueError:
        return words
    if len(quoted) != len(words) or any(_words(raw) != [word] for raw, word in zip(quoted, words)):
        return words
    return [glob.escape(word) if raw[0] in "'\"" else word for raw, word in zip(quoted, words)]


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


def _command_locations(command: str, cwd: Path) -> tuple[list[Path], bool]:
    locations = [cwd]
    unresolved = False
    tokens = _command_words(command)
    for index, token in enumerate(tokens[:-1]):
        if token not in {"cd", "pushd", "-C"}:
            continue
        target = tokens[index + 1]
        if _has_expansion(target):
            unresolved = True
            continue
        locations.append(Path(os.path.join(str(locations[-1]), target)).resolve())
    return locations, unresolved


def _parent_mutation(words: list[str], cwd: Path, identity: ProtectedIdentity) -> bool:
    if not any(os.path.basename(word) in {"rm", "mv", "rmdir"} for word in words):
        return False
    for value in _operand_values(words):
        target = _target(value, cwd)
        if target is None:
            continue
        parent = Path(target).resolve()
        if any(parent in module.resolve().parents for module in identity.modules):
            return True
    return False


def _command_hit(command: str, cwd: OptionalPath, scope: Scope) -> bool:
    parsed = _inspection_words(command, cwd)
    words = _fallback_words(command) if parsed is None else parsed
    if _files0_hit(words):
        return True
    if _marker_hit((command, " ".join(words)), scope.markers):
        return True
    if cwd is None:
        return False
    values = _operand_values(words)
    locations, unresolved = _command_locations(command, cwd)
    if any(_parent_mutation(words, location, scope.identity) for location in locations):
        return True
    if unresolved and _marker_hit((command,), SCRIPT_MARKERS):
        return True
    return any(_value_hit(value, location, scope.identity) for location in locations for value in values)


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


def _plain_source_glob(word: str, cwd: Path) -> bool:
    matches = expand_glob(os.path.join(str(cwd), word))
    return bool(matches) and all(
        Path(match).is_file() and not Path(match).is_symlink() for match in matches
    )


def _read_exempt(command: str, cwd: OptionalPath) -> bool:
    words = _inspection_words(command, cwd)
    if cwd is None or words is None or any(_has_expansion(word) for word in words):
        return False
    if any(_has_glob(word) and not _plain_source_glob(word, cwd) for word in words):
        return False
    simple = not OPERATOR_SPLIT.search(command)
    if simple and words and os.path.basename(words[0]) == "pwd":
        return True
    if simple and words and os.path.basename(words[0]) == "ls" and "-R" not in words:
        return True
    if simple and len(words) > 1 and words[:2] == ["git", "status"]:
        return True
    return is_source_inspection(command, str(cwd))


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


def _plugin_root() -> OptionalPath:
    candidate = os.environ.get("CLAUDE_PLUGIN_ROOT")
    try:
        root = Path(candidate) if candidate else Path(__file__).parent.parent
        resolved = root.resolve(strict=True)
        return resolved if resolved.is_dir() else None
    except (OSError, RuntimeError, ValueError):
        return None


def _installed_files(root: Path) -> set[Path]:
    return {
        root / "hooks", root / "scripts",
        *(root / "hooks" / name for name in GUARD_MODULES),
        root / "scripts" / "pending-decision.sh", root / "scripts" / "hook-batch.sh",
    }


def _owner_scope() -> Scope:
    directory = state_directory()
    identity = ProtectedIdentity.build(None, {directory, directory / "grant.json"})
    return Scope(identity, (str(state_directory()), "meridian-guard/"))


def _command_words(command: str) -> list[str]:
    words = _words(command)
    return _fallback_words(command) if words is None else words


def _runtime_script_execution(command: str, cwd: OptionalPath) -> bool:
    for segment in re.split(r"&&|\|\||;", command):
        if _read_exempt(segment, cwd):
            continue
        words = _command_words(segment)
        if not words:
            continue
        if os.path.basename(words[0]) in {"git", "printf", "echo", "tee", "sed"}:
            continue
        tokens = words + _fallback_words(" ".join(words))
        if any(os.path.basename(word.strip(QUOTE_CHARS)) in SCRIPT_MARKERS for word in tokens):
            return True
    return False


def _unlock_command(command: str, cwd: OptionalPath, cli: Scope) -> bool:
    if _command_hit(command, cwd, cli):
        return True
    words = _command_words(command)
    if any("guard_unlock" in word for word in words if "import" in word):
        return True
    if words and os.path.basename(words[0]) in {"git", "printf", "echo", "tee", "sed"}:
        return False
    return _marker_hit((command,), ("meridian-guard.sh", "guard_unlock"))


def _unlock_access(data: dict, cwd: OptionalPath, roots: set[Path]) -> bool:
    tool_input = data["tool_input"]
    owner = _owner_scope()
    paths = {"file_path": tool_input.get("path")}
    if _direct_hit(tool_input, cwd, owner) or _direct_hit(paths, cwd, owner):
        return True
    command = tool_input.get("command")
    if isinstance(command, str) and _command_hit(command, cwd, owner):
        return True
    if data.get("tool_name") in {"Read", "Grep", "Glob"}:
        return False
    cli_files = {root / "scripts" / "meridian-guard.sh" for root in roots}
    cli_files.update(root / "hooks" / "guard_unlock.py" for root in roots)
    cli = Scope(ProtectedIdentity.build(None, cli_files), ())
    if _direct_hit(tool_input, cwd, cli):
        return True
    if not isinstance(command, str) or _read_exempt(command, cwd):
        return False
    return _unlock_command(command, cwd, cli)


def _embedded_access(command: str, roots: set[Path], unlocked: bool) -> bool:
    return any(_embedded_segment(segment, roots, unlocked) for segment in command_segments(command))


def _embedded_segment(command: str, roots: set[Path], unlocked: bool) -> bool:
    words = _command_words(command)
    interpreters = {"bash", "sh", "zsh", "python", "python3", "perl", "node", "eval", "xargs"}
    if not any(os.path.basename(word) in interpreters for word in words):
        return False
    markers = (*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock", str(state_directory()))
    if not unlocked:
        markers += tuple(str(root / tree) for root in roots for tree in ("hooks", "scripts"))
    return _marker_hit((command,), markers)


def _grant_expansion(command: str) -> bool:
    words = _command_words(command)
    return any(
        any(marker in word for marker in ("-guard", "meridian", ".local/state", "grant.json"))
        and (any(char in word for char in EXPANSION_CHARS) or _has_glob(word))
        for word in words
    )


class Installation(NamedTuple):
    roots: set[Path]
    unresolved: bool
    unlocked: bool


def _shell_access(command: str, cwd: OptionalPath, installation: Installation) -> bool:
    return (
        _grant_expansion(command)
        or _embedded_access(command, installation.roots, installation.unlocked)
        or _runtime_script_execution(command, cwd)
    )


def _source_scope(data: dict, planning_dir: OptionalPath, installation: Installation) -> Scope:
    markers = PROTECTED_MARKERS if installation.unresolved else RUNTIME_MARKERS
    files: set[Path] = set()
    if data.get("tool_name") != "Read" and not installation.unlocked:
        files = {path for installed in installation.roots for path in _installed_files(installed)}
    command = data["tool_input"].get("command")
    if files and isinstance(command, str) and re.search(r"\b(cd|pushd)\b.*[$`~]", command):
        markers = PROTECTED_MARKERS
    return Scope(ProtectedIdentity.build(planning_dir, files), markers)


def _analyse(data: dict, planning_dir: OptionalPath) -> bool:
    cwd = current_directory(data.get("cwd"))
    root = _plugin_root()
    roots = {Path(__file__).resolve().parent.parent}
    if root is not None:
        roots.add(root)
    if _unlock_access(data, cwd, roots):
        return True
    installation = Installation(roots, root is None, active_expiry() is not None)
    command = data["tool_input"].get("command")
    if isinstance(command, str) and _shell_access(command, cwd, installation):
        return True
    scope = _source_scope(data, planning_dir, installation)
    return _evaluate(data, cwd, scope)


@contextmanager
def _deadline(seconds: float) -> Iterator[None]:
    def expire(_signum: int, _frame: object) -> None:
        raise AnalysisTimeout()

    try:
        previous = signal.signal(signal.SIGALRM, expire)
    except (ValueError, AttributeError):
        yield
        return
    started = time.monotonic()
    outer_timer = signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if outer_timer[0] > 0:
            remaining = max(0.000001, outer_timer[0] - (time.monotonic() - started))
            signal.setitimer(signal.ITIMER_REAL, remaining, outer_timer[1])


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
