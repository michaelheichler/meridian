from __future__ import annotations

import fnmatch
import os
import re
from enum import Enum
from pathlib import Path
from typing import Iterable, Optional

if __package__:
    from .brace_expansion import expand_braces
    from .command_view import CommandView
    from .guard_unlock import state_directory
    from .path_identity import GLOB_CHARS, within
    from .read_only_command import command_segments, traversal_roots
    from .shell_invocation import (
        EXPANSION_CHARS, QUOTE_CHARS, UNRESOLVED_CHARS, Invocation, command_words,
        expand_known_variables, invocation, runs_inline_code, segment_stages, stage_calls,
        stage_texts, statement_words,
    )
else:
    from brace_expansion import expand_braces
    from command_view import CommandView
    from guard_unlock import state_directory
    from path_identity import GLOB_CHARS, within
    from read_only_command import command_segments, traversal_roots
    from shell_invocation import (
        EXPANSION_CHARS, QUOTE_CHARS, UNRESOLVED_CHARS, Invocation, command_words,
        expand_known_variables, invocation, runs_inline_code, segment_stages, stage_calls,
        stage_texts, statement_words,
    )

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
    "command_policy.py",
    "git_policy.py",
    "brace_expansion.py",
    "path_identity.py",
)
SCRIPT_MARKERS = ("pending-decision.sh", "hook-batch.sh", "qa-phase.py", *GUARD_MODULES)
DENY_SET = frozenset({*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock.py"})
GUARD_STEMS = frozenset({*(name[: -len(".py")] for name in GUARD_MODULES), "guard_unlock"})
STEM_PATTERN = re.compile(r"(?<![\w])(?:" + "|".join(sorted(GUARD_STEMS)) + r")(?![\w])")
RUNTIME_MARKERS = (".meridian/.runtime", ".runtime/decisions", ".hook-transitions")
PROTECTED_MARKERS = (
    *SCRIPT_MARKERS, *RUNTIME_MARKERS, "hooks.json", "__init__.py",
    "guard_unlock.py", "meridian-guard.sh", "session-start.sh",
)
GRANT_NAMES = ("meridian-guard", ".local/state", "grant.json")
PASSIVE_PROGRAMS = frozenset({"git", "printf", "echo", "tee", "sed"})
PROTECTED_TREES = ("hooks", "scripts")
PLUGIN_ROOT_VARIABLE = "CLAUDE_PLUGIN_ROOT"
AWK_RUNNERS = ("system", "|")
INLINE_QUOTES = str.maketrans("", "", "'\"")
class Access(Enum):
    SOURCE = "source"
    EXECUTION = "execution"
    INLINE_CODE = "inline-code"
    RUNTIME = "runtime"
    GRANT = "grant"
    UNRESOLVED = "unresolved"


def marker_hit(texts: Iterable[str], markers: tuple[str, ...]) -> bool:
    folded = [text.casefold() for text in texts]
    return any(marker.casefold() in text for marker in markers for text in folded)


def has_glob(value: str) -> bool:
    return any(char in value for char in GLOB_CHARS)


def _deny_name(name: str) -> bool:
    bare = name.strip(QUOTE_CHARS)
    if has_glob(bare):
        return any(fnmatch.fnmatchcase(member, bare) for member in DENY_SET)
    return bare in DENY_SET


def _deny_target(target: str, cwd: Optional[Path]) -> bool:
    for name in expand_braces(expand_known_variables(target)):
        names = {os.path.basename(name)}
        if cwd is not None:
            resolved = os.path.realpath(os.path.join(str(cwd), os.path.expanduser(name)))
            names.add(os.path.basename(resolved))
        if any(_deny_name(candidate) for candidate in names):
            return True
    return False


def _guard_module(module: Optional[str]) -> bool:
    return module is not None and module.rsplit(".", 1)[-1] in GUARD_STEMS


def _segment_calls(segment: str) -> list[Invocation]:
    calls = stage_calls(segment)
    if calls is None:
        calls = [invocation(words) for words in statement_words(segment)]
    return [call for call in calls if call is not None]


def _program_names_deny_set(call: Invocation) -> bool:
    code = call.code or ""
    runs = call.family == "awk" and any(marker in code for marker in AWK_RUNNERS)
    return runs and marker_hit((code,), tuple(DENY_SET))


def _segment_runs_deny_set(segment: str, cwd: Optional[Path]) -> bool:
    calls = _segment_calls(segment)
    if any(_guard_module(call.module) or _program_names_deny_set(call) for call in calls):
        return True
    return any(call.target is not None and _deny_target(call.target, cwd) for call in calls)


def runs_deny_set(command: str, cwd: Optional[Path]) -> bool:
    return any(_segment_runs_deny_set(segment, cwd) for segment in command_segments(command))


def _reaches_plugin_root(code: str, trees: tuple[str, ...]) -> bool:
    return bool(trees) and PLUGIN_ROOT_VARIABLE in code and marker_hit((code,), PROTECTED_TREES)


def _embedded_segment(segment: str, trees: tuple[str, ...]) -> bool:
    if not runs_inline_code(segment):
        return False
    code = expand_known_variables(segment).translate(INLINE_QUOTES)
    markers = (*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock", str(state_directory()))
    if marker_hit((segment, code), (*markers, *trees)) or _reaches_plugin_root(code, trees):
        return True
    return "import" in segment and STEM_PATTERN.search(segment) is not None


def embedded_access(command: str, trees: tuple[str, ...]) -> bool:
    return any(_embedded_segment(segment, trees) for segment in command_segments(command))


def grant_expansion(command: str) -> bool:
    return any(
        any(name in word for name in GRANT_NAMES)
        and (any(char in word for char in EXPANSION_CHARS) or has_glob(word))
        for word in command_words(command)
    )


def protected_targets(planning_dir: Optional[Path]) -> list[tuple[Path, Access]]:
    targets = [(state_directory(), Access.GRANT)]
    if planning_dir is not None:
        targets.append((planning_dir / ".runtime", Access.RUNTIME))
    return [(path, access) for path, access in targets if path.exists()]


def reached(root: str, location: Path, targets: list[tuple[Path, Access]]) -> Optional[Access]:
    expanded = expand_known_variables(root)
    if any(char in expanded for char in UNRESOLVED_CHARS):
        return None
    real = os.path.realpath(os.path.join(str(location), os.path.expanduser(expanded)))
    for target, access in targets:
        if within(os.path.realpath(target), real):
            return access
    return None


def stage_roots(command: str) -> list[str]:
    roots: list[str] = []
    for segment in command_segments(command):
        for stage in segment_stages(segment) or []:
            roots.extend(traversal_roots(stage_texts(stage)) or [])
    return roots


def hidden_gap(root: str, target: Path) -> bool:
    parts = Path(os.path.relpath(os.path.realpath(target), root)).parts
    return any(part.startswith(".") for part in parts[:-1])


def _embeds_tree(word: str, markers: tuple[str, ...]) -> bool:
    parts = word.casefold().split("=")
    folded = tuple(marker.casefold() for marker in markers)
    return marker_hit((word,), markers) and not any(part.startswith(folded) for part in parts)


def mention_access(view: CommandView, trees: tuple[str, ...]) -> Optional[Access]:
    for segment in view.unclassified:
        if marker_hit((segment.source_text,), RUNTIME_MARKERS):
            return Access.RUNTIME
        if marker_hit((segment.source_text,), (str(state_directory()),)):
            return Access.GRANT
        if trees and any(_embeds_tree(word, trees) for word in segment.source_words):
            return Access.SOURCE
    return None
