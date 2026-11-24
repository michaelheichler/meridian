from __future__ import annotations

import os
import re
import signal
import time
from contextlib import contextmanager
from enum import Enum
from pathlib import Path
from typing import Iterable, Iterator, NamedTuple, Optional

if __package__:
    from .brace_expansion import ExpansionTooComplex, expand_braces
    from .decision_common import INVALID_STATE, DecisionStateError, require
    from .path_identity import ProtectedIdentity, TooManyMatches, expand_glob, iter_matches
    from .command_view import CommandView, command_view
    from .read_only_command import command_segments
    from .shell_invocation import (
        command_words, fallback_words, invocation, runs_inline_code, segment_stages,
    )
    from .guard_unlock import active_expiry, state_directory
    from .qa_command import permits_qa_command
else:
    from brace_expansion import ExpansionTooComplex, expand_braces
    from decision_common import INVALID_STATE, DecisionStateError, require
    from path_identity import ProtectedIdentity, TooManyMatches, expand_glob, iter_matches
    from command_view import CommandView, command_view
    from read_only_command import command_segments
    from shell_invocation import (
        command_words, fallback_words, invocation, runs_inline_code, segment_stages,
    )
    from guard_unlock import active_expiry, state_directory
    from qa_command import permits_qa_command

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
    "qa_command.py",
    "read_only_command.py",
    "shell_invocation.py",
    "command_view.py",
    "brace_expansion.py",
    "path_identity.py",
)
SCRIPT_MARKERS = ("pending-decision.sh", "hook-batch.sh", "qa-phase.py", *GUARD_MODULES)
DENY_SET = frozenset({*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock.py"})
RUNTIME_MARKERS = (".meridian/.runtime", ".runtime/decisions", ".hook-transitions")
PROTECTED_MARKERS = (
    *SCRIPT_MARKERS, *RUNTIME_MARKERS, "hooks.json", "__init__.py",
    "guard_unlock.py", "meridian-guard.sh", "session-start.sh",
)
GRANT_NAMES = ("meridian-guard", ".local/state", "grant.json")
PASSIVE_PROGRAMS = frozenset({"git", "printf", "echo", "tee", "sed"})
EXPANSION_CHARS = "$`{"
UNRESOLVED_CHARS = "$`"
GLOB_CHARS = "*?["
HOME_VARIABLE = re.compile(r"\$(?:\{HOME\}|HOME(?![A-Za-z0-9_]))")
SUFFIX_SPAN = 8
ANALYSIS_SECONDS = 3.5
TIMEOUT_REASON = "guard analysis timeout"
SEARCH_TOOLS = frozenset({"Grep", "Glob"})
QUOTE_CHARS = "$'\""
FILES0_OPTION = "--files0-from"
FILES0_PREFIX = "--files0"
FILES0_COMMANDS = frozenset({"sort", "wc"})
FILES0_ABBREVIATION_FLOOR = 3
OPERATOR_SPLIT = re.compile(r"[<>&|;()]")


class AnalysisTimeout(Exception):
    pass


class Access(Enum):
    SOURCE = "source"
    EXECUTION = "execution"
    INLINE_CODE = "inline-code"
    RUNTIME = "runtime"
    GRANT = "grant"
    UNRESOLVED = "unresolved"


class Scope(NamedTuple):
    identity: ProtectedIdentity
    markers: tuple[str, ...]


class Probe(NamedTuple):
    command: str
    words: list[str]
    text: str


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
    value = HOME_VARIABLE.sub(lambda _match: os.path.expanduser("~"), value)
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
    tokens = command_words(command)
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


def _probe_hit(probe: Probe, cwd: OptionalPath, scope: Scope) -> bool:
    if _files0_hit(probe.words):
        return True
    if _marker_hit((probe.text, " ".join(probe.words)), scope.markers):
        return True
    if cwd is None:
        return False
    locations, unresolved = _command_locations(probe.command, cwd)
    if any(_parent_mutation(probe.words, location, scope.identity) for location in locations):
        return True
    if unresolved and _marker_hit((probe.text,), SCRIPT_MARKERS):
        return True
    values = _operand_values(probe.words)
    pairs = ((value, location) for location in locations for value in values)
    return any(_value_hit(value, location, scope.identity) for value, location in pairs)


def _pattern_hit(pattern: str, root: Path, identity: ProtectedIdentity) -> bool:
    target = _target(pattern, root)
    if target is None:
        return False
    if not _has_glob(pattern):
        return identity.hits(target)
    return identity.glob_hits(target) or any(identity.hits(match) for match in iter_matches(target))


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
    return any(_pattern_hit(item, Path(root), scoped) for item in expand_braces(pattern))


def _every_word_probe(view: CommandView) -> Probe:
    return Probe(view.command, view.loose + view.strict, view.command)


def _whole_probe(view: Optional[CommandView]) -> Optional[Probe]:
    return None if view is None else _every_word_probe(view)


def _strict_probe(view: Optional[CommandView]) -> Optional[Probe]:
    return None if view is None else Probe(view.command, view.strict, view.strict_text)


def _tool_hit(data: dict, cwd: OptionalPath, scope: Scope, probe: Optional[Probe]) -> bool:
    if _direct_hit(data["tool_input"], cwd, scope) or _search_hit(data, cwd, scope.identity):
        return True
    return probe is not None and _probe_hit(probe, cwd, scope)


def _evaluate(
    data: dict, cwd: OptionalPath, full: Scope, view: Optional[CommandView],
) -> Optional[Access]:
    runtime = Scope(full.identity.runtime_only(), RUNTIME_MARKERS)
    if _tool_hit(data, cwd, runtime, _whole_probe(view)):
        return Access.RUNTIME
    if _tool_hit(data, cwd, full, _strict_probe(view)):
        return Access.SOURCE
    return None


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
        root / "agents" / "phase-qa.md",
        *(root / "hooks" / name for name in GUARD_MODULES),
        root / "scripts" / "pending-decision.sh", root / "scripts" / "hook-batch.sh",
    }


def _owner_scope() -> Scope:
    directory = state_directory()
    identity = ProtectedIdentity.build(None, {directory, directory / "grant.json"})
    return Scope(identity, (str(state_directory()), "meridian-guard/"))


def _mentions_deny_set(segment: str) -> bool:
    words = command_words(segment)
    if not words or os.path.basename(words[0]) in PASSIVE_PROGRAMS:
        return False
    tokens = words + fallback_words(" ".join(words))
    return any(os.path.basename(word.strip(QUOTE_CHARS)) in DENY_SET for word in tokens)


def _deny_target(target: str, cwd: OptionalPath) -> bool:
    for name in expand_braces(target):
        names = {os.path.basename(name)}
        if cwd is not None:
            resolved = os.path.realpath(os.path.join(str(cwd), os.path.expanduser(name)))
            names.add(os.path.basename(resolved))
        if names & DENY_SET:
            return True
    return False


def _segment_runs_deny_set(segment: str, cwd: OptionalPath) -> bool:
    stages = segment_stages(segment)
    if stages is None:
        return _mentions_deny_set(segment)
    calls = (invocation([token.text for token in stage.words]) for stage in stages)
    targets = (call.target for call in calls if call is not None and call.target is not None)
    return any(_deny_target(target, cwd) for target in targets)


def _runs_deny_set(command: str, cwd: OptionalPath) -> bool:
    return any(_segment_runs_deny_set(segment, cwd) for segment in command_segments(command))


def _unlock_command(view: CommandView, cwd: OptionalPath, cli: Scope) -> bool:
    if _probe_hit(_every_word_probe(view), cwd, cli):
        return True
    words = command_words(view.command)
    if any("guard_unlock" in word for word in words if "import" in word):
        return True
    if words and os.path.basename(words[0]) in PASSIVE_PROGRAMS:
        return False
    return _marker_hit((view.command,), ("meridian-guard.sh", "guard_unlock"))


def _unlock_access(
    data: dict, cwd: OptionalPath, roots: set[Path], view: Optional[CommandView],
) -> bool:
    tool_input = data["tool_input"]
    owner = _owner_scope()
    paths = {"file_path": tool_input.get("path")}
    if _direct_hit(tool_input, cwd, owner) or _direct_hit(paths, cwd, owner):
        return True
    whole = _whole_probe(view)
    if whole is not None and _probe_hit(whole, cwd, owner):
        return True
    if data.get("tool_name") in {"Read", "Grep", "Glob"}:
        return False
    cli_files = {root / "scripts" / "meridian-guard.sh" for root in roots}
    cli_files.update(root / "hooks" / "guard_unlock.py" for root in roots)
    cli = Scope(ProtectedIdentity.build(None, cli_files), ())
    if _direct_hit(tool_input, cwd, cli):
        return True
    if view is None or view.reads_only:
        return False
    return _unlock_command(view, cwd, cli)


def _embedded_access(command: str, roots: set[Path], unlocked: bool) -> bool:
    return any(_embedded_segment(segment, roots, unlocked) for segment in command_segments(command))


def _embedded_segment(command: str, roots: set[Path], unlocked: bool) -> bool:
    if not runs_inline_code(command):
        return False
    markers = (*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock", str(state_directory()))
    if not unlocked:
        markers += tuple(str(root / tree) for root in roots for tree in ("hooks", "scripts"))
    return _marker_hit((command,), markers)


def _grant_expansion(command: str) -> bool:
    return any(
        any(name in word for name in GRANT_NAMES)
        and (any(char in word for char in EXPANSION_CHARS) or _has_glob(word))
        for word in command_words(command)
    )


class Installation(NamedTuple):
    roots: set[Path]
    unresolved: bool
    unlocked: bool


def _shell_access(command: str, cwd: OptionalPath, installation: Installation) -> Optional[Access]:
    if _grant_expansion(command):
        return Access.GRANT
    if _embedded_access(command, installation.roots, installation.unlocked):
        return Access.INLINE_CODE
    if _runs_deny_set(command, cwd):
        return Access.EXECUTION
    return None


def _source_scope(data: dict, planning_dir: OptionalPath, installation: Installation) -> Scope:
    markers = PROTECTED_MARKERS if installation.unresolved else RUNTIME_MARKERS
    files: set[Path] = set()
    if data.get("tool_name") != "Read" and not installation.unlocked:
        files = {path for installed in installation.roots for path in _installed_files(installed)}
    command = data["tool_input"].get("command")
    if files and isinstance(command, str) and re.search(r"\b(cd|pushd)\b.*[$`~]", command):
        markers = PROTECTED_MARKERS
    return Scope(ProtectedIdentity.build(planning_dir, files), markers)


def _analyse(data: dict, planning_dir: OptionalPath) -> Optional[Access]:
    cwd = current_directory(data.get("cwd"))
    root = _plugin_root()
    roots = {Path(__file__).resolve().parent.parent}
    if root is not None:
        roots.add(root)
    if permits_qa_command(data, cwd, planning_dir, roots):
        return None
    command = data["tool_input"].get("command")
    view = command_view(command, cwd) if isinstance(command, str) else None
    if _unlock_access(data, cwd, roots, view):
        return Access.GRANT
    installation = Installation(roots, root is None, active_expiry() is not None)
    shell = None if view is None else _shell_access(view.command, cwd, installation)
    if shell is not None:
        return shell
    return _evaluate(data, cwd, _source_scope(data, planning_dir, installation), view)


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


def protected_access(data: dict, planning_dir: OptionalPath) -> Optional[Access]:
    if not isinstance(data.get("tool_input"), dict):
        return None
    try:
        with _deadline(ANALYSIS_SECONDS):
            return _analyse(data, planning_dir)
    except AnalysisTimeout:
        raise DecisionStateError(TIMEOUT_REASON) from None
    except (ExpansionTooComplex, TooManyMatches, ValueError):
        return Access.UNRESOLVED
