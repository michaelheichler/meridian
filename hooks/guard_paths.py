from __future__ import annotations

import os
import re
import signal
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Iterator, NamedTuple, Optional

if __package__:
    from .brace_expansion import ExpansionTooComplex, expand_braces
    from .command_policy import (
        GUARD_MODULES, PASSIVE_PROGRAMS, PROTECTED_MARKERS, PROTECTED_TREES, RUNTIME_MARKERS,
        SCRIPT_MARKERS, Access, GitCall, configures_commands, embedded_access, git_call, grant_expansion,
        has_glob, hidden_gap, marker_hit, mention_access, mutates_tree, protected_targets, reached,
        runs_deny_set, stage_roots,
    )
    from .command_view import CommandView, ViewContext, command_locations, command_view
    from .decision_common import INVALID_STATE, DecisionStateError, require
    from .guard_unlock import active_expiry, state_directory
    from .path_identity import (
        GLOB_CHARS, ProtectedIdentity, TooManyMatches, expand_glob, iter_matches, within,
    )
    from .qa_command import permits_qa_command
    from .read_only_command import command_segments
    from .shell_invocation import (
        UNRESOLVED_CHARS, command_words, expand_known_variables, segment_stages, stage_texts,
    )
else:
    from brace_expansion import ExpansionTooComplex, expand_braces
    from command_policy import (
        GUARD_MODULES, PASSIVE_PROGRAMS, PROTECTED_MARKERS, PROTECTED_TREES, RUNTIME_MARKERS,
        SCRIPT_MARKERS, Access, GitCall, configures_commands, embedded_access, git_call, grant_expansion,
        has_glob, hidden_gap, marker_hit, mention_access, mutates_tree, protected_targets, reached,
        runs_deny_set, stage_roots,
    )
    from command_view import CommandView, ViewContext, command_locations, command_view
    from decision_common import INVALID_STATE, DecisionStateError, require
    from guard_unlock import active_expiry, state_directory
    from path_identity import (
        GLOB_CHARS, ProtectedIdentity, TooManyMatches, expand_glob, iter_matches, within,
    )
    from qa_command import permits_qa_command
    from read_only_command import command_segments
    from shell_invocation import (
        UNRESOLVED_CHARS, command_words, expand_known_variables, segment_stages, stage_texts,
    )

OptionalPath = Optional[Path]
UNRESOLVED_PATTERN = re.compile(f"[{re.escape(UNRESOLVED_CHARS)}]")
SUFFIX_SPAN = 8
ANALYSIS_SECONDS = 3.5
TIMEOUT_REASON = "guard analysis timeout"
SEARCH_TOOLS = frozenset({"Grep", "Glob"})
FILES0_OPTION = "--files0-from"
FILES0_PREFIX = "--files0"
FILES0_COMMANDS = frozenset({"sort", "wc"})
FILES0_ABBREVIATION_FLOOR = 3
OPERATOR_SPLIT = re.compile(r"[<>&|;()]")
LOCATION_COMMANDS = frozenset({"cd", "pushd"})


class AnalysisTimeout(Exception):
    pass


class Scope(NamedTuple):
    identity: ProtectedIdentity
    markers: tuple[str, ...]
    guarded_names: tuple[str, ...] = ()


class Probe(NamedTuple):
    command: str
    words: tuple[str, ...]
    text: str


class Installation(NamedTuple):
    roots: frozenset[Path]
    unresolved: bool
    unlocked: bool


class Request(NamedTuple):
    data: dict
    cwd: OptionalPath
    planning_dir: OptionalPath
    installation: Installation
    view: Optional[CommandView]


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


def has_glob(value: str) -> bool:
    return any(char in value for char in GLOB_CHARS)


def _candidates(word: str) -> set[str]:
    values = {word, *word.split("="), *OPERATOR_SPLIT.split(word)}
    if word.startswith("-"):
        values.update(word[index:] for index in range(1, min(len(word), SUFFIX_SPAN)))
    return {value for value in values if value}


def _operand_values(words: Iterable[str]) -> list[str]:
    candidates = (value for word in words for value in _candidates(word))
    return [item for value in candidates for item in expand_braces(value)]


def _target(value: str, cwd: Path) -> Optional[str]:
    value = expand_known_variables(value)
    if any(char in value for char in UNRESOLVED_CHARS):
        return None
    return os.path.join(str(cwd), os.path.expanduser(value))


def _value_hit(value: str, cwd: Path, identity: ProtectedIdentity) -> bool:
    target = _target(value, cwd)
    if target is None:
        return False
    paths = [target]
    if has_glob(value):
        if identity.glob_hits(target):
            return True
        paths = expand_glob(target)
    return any(identity.hits(path) for path in paths)


def _unresolved_hit(word: str, cwd: Path, scope: Scope) -> bool:
    expanded = expand_known_variables(word)
    found = UNRESOLVED_PATTERN.search(expanded)
    if found is None or not scope.guarded_names or any(char.isspace() for char in expanded):
        return False
    if marker_hit((expanded,), scope.guarded_names):
        return True
    prefix = expanded[: found.start()]
    if "/" not in prefix:
        return False
    folder = os.path.join(str(cwd), os.path.expanduser(prefix[: prefix.rfind("/") + 1]))
    return scope.identity.hits(folder) or scope.identity.holds_module_below(folder)


def _direct_hit(tool_input: dict, cwd: OptionalPath, scope: Scope) -> bool:
    values = [tool_input.get("file_path"), tool_input.get("notebook_path")]
    texts = [value for value in values if isinstance(value, str)]
    if marker_hit(texts, scope.markers):
        return True
    paths = [os.path.join(str(cwd), text) for text in texts] if cwd else []
    return any(scope.identity.hits(path) for path in paths)


def _is_files0_option(word: str, floor: int) -> bool:
    name = word.split("=", 1)[0]
    return len(name) >= floor and FILES0_OPTION.startswith(name)


def _files0_hit(words: tuple[str, ...]) -> bool:
    sorting = any(os.path.basename(word) in FILES0_COMMANDS for word in words)
    floor = FILES0_ABBREVIATION_FLOOR if sorting else len(FILES0_PREFIX)
    return any(_is_files0_option(word, floor) for word in words)


def _parent_mutation(words: tuple[str, ...], cwd: Path, identity: ProtectedIdentity) -> bool:
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
    if marker_hit((probe.text, " ".join(probe.words)), scope.markers):
        return True
    if cwd is None:
        return False
    locations, unresolved = command_locations(probe.command, cwd)
    if any(_parent_mutation(probe.words, location, scope.identity) for location in locations):
        return True
    if unresolved and marker_hit((probe.text,), SCRIPT_MARKERS):
        return True
    unresolved_words = ((word, location) for location in locations for word in probe.words)
    if any(_unresolved_hit(word, location, scope) for word, location in unresolved_words):
        return True
    pairs = [(value, location) for location in locations for value in _operand_values(probe.words)]
    return any(_value_hit(value, location, scope.identity) for value, location in pairs)


def _pattern_hit(pattern: str, root: Path, identity: ProtectedIdentity) -> bool:
    target = _target(pattern, root)
    if target is None:
        return False
    if not has_glob(pattern):
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
    if marker_hit(texts, RUNTIME_MARKERS) or scoped.hits(root):
        return True
    if not isinstance(pattern, str):
        return False
    return any(_pattern_hit(item, Path(root), scoped) for item in expand_braces(pattern))


def _every_word_probe(view: CommandView) -> Probe:
    return Probe(view.command, view.every_word, view.command)


def _whole_probe(view: Optional[CommandView]) -> Optional[Probe]:
    return None if view is None else _every_word_probe(view)


def _source_probe(view: Optional[CommandView]) -> Optional[Probe]:
    return None if view is None else Probe(view.command, view.source_words, view.source_text)


def _tool_hit(data: dict, cwd: OptionalPath, scope: Scope, probe: Optional[Probe]) -> bool:
    if _direct_hit(data["tool_input"], cwd, scope) or _search_hit(data, cwd, scope.identity):
        return True
    return probe is not None and _probe_hit(probe, cwd, scope)


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


def _unlock_command(view: CommandView, cwd: OptionalPath, cli: Scope) -> bool:
    if _probe_hit(_every_word_probe(view), cwd, cli):
        return True
    words = command_words(view.command)
    if any("guard_unlock" in word for word in words if "import" in word):
        return True
    if words and os.path.basename(words[0]) in PASSIVE_PROGRAMS:
        return False
    return marker_hit((view.command,), ("meridian-guard.sh", "guard_unlock"))


def _unlock_access(request: Request) -> bool:
    data, cwd, view = request.data, request.cwd, request.view
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
    roots = request.installation.roots
    cli_files = {root / "scripts" / "meridian-guard.sh" for root in roots}
    cli_files.update(root / "hooks" / "guard_unlock.py" for root in roots)
    cli = Scope(ProtectedIdentity.build(None, cli_files), ())
    if _direct_hit(tool_input, cwd, cli):
        return True
    if view is None or view.reads_only:
        return False
    return _unlock_command(view, cwd, cli)


def _tree_markers(installation: Installation) -> tuple[str, ...]:
    if installation.unlocked:
        return ()
    return tuple(str(root / tree) for root in installation.roots for tree in PROTECTED_TREES)


def _near_installation(location: Path, installation: Installation) -> bool:
    return any(
        within(str(location), str(root)) or within(str(root), str(location))
        for root in installation.roots
    )


def _git_calls(command: str) -> list[GitCall]:
    calls = []
    for segment in command_segments(command):
        stages = segment_stages(segment)
        texts = [stage_texts(stage) for stage in stages] if stages is not None else []
        words_list = texts or [command_words(segment)]
        calls.extend(call for call in map(git_call, words_list) if call is not None)
    return calls


def _git_access(request: Request) -> bool:
    command = request.data["tool_input"]["command"]
    calls = _git_calls(command)
    if any(configures_commands(call) for call in calls):
        return True
    if request.installation.unlocked or request.cwd is None:
        return False
    locations, _unresolved = command_locations(command, request.cwd)
    near = any(_near_installation(location, request.installation) for location in locations)
    return near and any(mutates_tree(call) for call in calls)


def _traversal_access(request: Request) -> Optional[Access]:
    targets = protected_targets(request.planning_dir)
    if request.cwd is None or not targets:
        return None
    command = request.data["tool_input"]["command"]
    locations, _unresolved = command_locations(command, request.cwd)
    for root in stage_roots(command):
        for location in locations:
            access = reached(root, location, targets)
            if access is not None:
                return access
    return None


def _search_traversal(request: Request) -> Optional[Access]:
    if request.data.get("tool_name") != "Grep" or request.cwd is None:
        return None
    base = request.data["tool_input"].get("path")
    root = os.path.realpath(os.path.join(str(request.cwd), base if isinstance(base, str) else "."))
    for target, access in protected_targets(request.planning_dir):
        if within(os.path.realpath(target), root) and not hidden_gap(root, target):
            return access
    return None


def _shell_access(request: Request) -> Optional[Access]:
    command = request.data["tool_input"]["command"]
    if grant_expansion(command):
        return Access.GRANT
    if runs_deny_set(command, request.cwd):
        return Access.EXECUTION
    if embedded_access(command, _tree_markers(request.installation)):
        return Access.INLINE_CODE
    if _git_access(request):
        return Access.SOURCE
    return None


def _source_scope(request: Request) -> Scope:
    installation = request.installation
    markers = PROTECTED_MARKERS if installation.unresolved else RUNTIME_MARKERS
    files: set[Path] = set()
    if request.data.get("tool_name") != "Read" and not installation.unlocked:
        files = {path for installed in installation.roots for path in _installed_files(installed)}
    command = request.data["tool_input"].get("command")
    if files and isinstance(command, str) and re.search(r"\b(cd|pushd)\b.*[$`~]", command):
        markers = PROTECTED_MARKERS
    guarded = SCRIPT_MARKERS if files else ()
    return Scope(ProtectedIdentity.build(request.planning_dir, files), markers, guarded)


def _evaluate(request: Request) -> Optional[Access]:
    data, cwd, view = request.data, request.cwd, request.view
    full = _source_scope(request)
    runtime = Scope(full.identity.runtime_only(), RUNTIME_MARKERS)
    if _tool_hit(data, cwd, runtime, _whole_probe(view)):
        return Access.RUNTIME
    traversal = _search_traversal(request) if view is None else _traversal_access(request)
    if traversal is not None:
        return traversal
    if _tool_hit(data, cwd, full, _source_probe(view)):
        return Access.SOURCE
    return None if view is None else mention_access(view, _tree_markers(request.installation))


def _request(data: dict, planning_dir: OptionalPath) -> Request:
    cwd = current_directory(data.get("cwd"))
    root = _plugin_root()
    roots = {Path(__file__).resolve().parent.parent}
    if root is not None:
        roots.add(root)
    installation = Installation(
        frozenset(roots), unresolved=root is None, unlocked=active_expiry() is not None,
    )
    command = data["tool_input"].get("command")
    helpers = frozenset(str(path / "scripts").casefold() for path in roots)
    context = None if cwd is None else ViewContext(cwd, helpers)
    view = command_view(command, context) if isinstance(command, str) else None
    return Request(data, cwd, planning_dir, installation, view)


def _analyse(data: dict, planning_dir: OptionalPath) -> Optional[Access]:
    request = _request(data, planning_dir)
    if permits_qa_command(data, request.cwd, planning_dir, set(request.installation.roots)):
        return None
    if _unlock_access(request):
        return Access.GRANT
    shell = None if request.view is None else _shell_access(request)
    return shell if shell is not None else _evaluate(request)


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
