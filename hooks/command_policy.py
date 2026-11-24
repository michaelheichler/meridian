from __future__ import annotations

import fnmatch
import os
import re
from enum import Enum
from pathlib import Path
from typing import Iterable, NamedTuple, Optional

if __package__:
    from .brace_expansion import expand_braces
    from .command_view import CommandView
    from .guard_unlock import state_directory
    from .path_identity import GLOB_CHARS, within
    from .read_only_command import command_segments, traversal_roots
    from .shell_invocation import (
        ASSIGNMENT, EXPANSION_CHARS, QUOTE_CHARS, command_words, expand_known_variables,
        fallback_words, invocation, runs_inline_code, segment_stages, stage_calls, stage_texts,
    )
else:
    from brace_expansion import expand_braces
    from command_view import CommandView
    from guard_unlock import state_directory
    from path_identity import GLOB_CHARS, within
    from read_only_command import command_segments, traversal_roots
    from shell_invocation import (
        ASSIGNMENT, EXPANSION_CHARS, QUOTE_CHARS, command_words, expand_known_variables,
        fallback_words, invocation, runs_inline_code, segment_stages, stage_calls, stage_texts,
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
UNRESOLVED_CHARS = "$`"
UNRESOLVED_PATTERN = re.compile(r"[$`]")
COMMAND_KEY_PARTS = (
    "pager", "editor", "ssh", r"alias\.", "external", "textconv", "fsmonitor", "hookspath",
    "askpass", r"filter\.", "program", "helper", "include",
)
COMMAND_KEYS = re.compile("|".join(COMMAND_KEY_PARTS), re.IGNORECASE)
COMMAND_ENVIRONMENT = re.compile(
    r"GIT_(?:PAGER|EDITOR|SEQUENCE_EDITOR|SSH|SSH_COMMAND|EXTERNAL_DIFF|ASKPASS|CONFIG\w*)="
)
VALUED_GLOBALS = frozenset({"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"})
TREE_MUTATIONS = frozenset({
    "reset", "checkout", "switch", "restore", "stash", "apply", "am", "merge", "pull",
    "rebase", "clean", "cherry-pick", "revert", "rm", "mv",
})
BRANCH_CREATION = frozenset({"-b", "-c"})
STASH_READS = frozenset({"list", "show"})
CONFIG_READS = frozenset({
    "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
    "--show-origin", "--show-scope", "get", "list",
})
CONFIG_EDITS = frozenset({"-e", "--edit", "edit"})


class GitCall(NamedTuple):
    environment: tuple[str, ...]
    settings: tuple[str, ...]
    subcommand: Optional[str]
    args: tuple[str, ...]


def _globals(args: list[str]) -> tuple[list[str], int]:
    settings: list[str] = []
    index = 0
    while index < len(args) and args[index].startswith("-"):
        flag = args[index]
        if flag == "-c" or flag == "--config-env":
            settings.append(args[index + 1] if index + 1 < len(args) else "")
            index += 2
        elif flag.startswith("--config-env="):
            settings.append(flag.split("=", 1)[1])
            index += 1
        else:
            index += 2 if flag in VALUED_GLOBALS else 1
    return settings, index


def git_call(words: list[str]) -> Optional[GitCall]:
    call = invocation(words)
    if call is None or call.target is None or os.path.basename(call.target) != "git":
        return None
    start = words.index(call.target)
    environment = tuple(word for word in words[:start] if ASSIGNMENT.fullmatch(word))
    settings, index = _globals(words[start + 1 :])
    rest = words[start + 1 + index :]
    subcommand = rest[0] if rest else None
    return GitCall(environment, tuple(settings), subcommand, tuple(rest[1:]))


def _config_writes_commands(args: tuple[str, ...]) -> bool:
    if any(arg in CONFIG_READS for arg in args):
        return False
    if any(arg in CONFIG_EDITS for arg in args):
        return True
    keys = [arg for arg in args if not arg.startswith("-") and arg != "set"]
    return bool(keys) and bool(COMMAND_KEYS.search(keys[0]))


def configures_commands(call: GitCall) -> bool:
    if any(COMMAND_ENVIRONMENT.match(assignment) for assignment in call.environment):
        return True
    if any(COMMAND_KEYS.search(setting.split("=", 1)[0]) for setting in call.settings):
        return True
    return call.subcommand == "config" and _config_writes_commands(call.args)


def mutates_tree(call: GitCall) -> bool:
    if call.subcommand not in TREE_MUTATIONS:
        return False
    if call.subcommand in ("checkout", "switch") and len(call.args) == 2:
        return call.args[0] not in BRANCH_CREATION
    return call.subcommand != "stash" or not call.args or call.args[0] not in STASH_READS


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


def _mentions_deny_set(segment: str) -> bool:
    words = command_words(segment)
    if not words or os.path.basename(words[0]) in PASSIVE_PROGRAMS:
        return False
    tokens = words + fallback_words(" ".join(words))
    return any(os.path.basename(word.strip(QUOTE_CHARS)) in DENY_SET for word in tokens)


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


def _segment_runs_deny_set(segment: str, cwd: Optional[Path]) -> bool:
    calls = stage_calls(segment)
    if calls is None:
        return _mentions_deny_set(segment)
    present = [call for call in calls if call is not None]
    if any(_guard_module(call.module) for call in present):
        return True
    return any(call.target is not None and _deny_target(call.target, cwd) for call in present)


def runs_deny_set(command: str, cwd: Optional[Path]) -> bool:
    return any(_segment_runs_deny_set(segment, cwd) for segment in command_segments(command))


def _embedded_segment(segment: str, trees: tuple[str, ...]) -> bool:
    if not runs_inline_code(segment):
        return False
    markers = (*SCRIPT_MARKERS, "meridian-guard.sh", "guard_unlock", str(state_directory()))
    if marker_hit((segment,), (*markers, *trees)):
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
    for text in view.unclassified_texts:
        if marker_hit((text,), RUNTIME_MARKERS):
            return Access.RUNTIME
        if marker_hit((text,), (str(state_directory()),)):
            return Access.GRANT
        if trees and any(_embeds_tree(word, trees) for word in command_words(text)):
            return Access.SOURCE
        if _mentions_deny_set(text):
            return Access.EXECUTION
    return None
