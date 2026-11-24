from __future__ import annotations

import os
import re
from typing import NamedTuple, Optional

if __package__:
    from .read_only_command import command_segments
    from .shell_invocation import (
        ASSIGNMENT, command_words, invocation, segment_stages, stage_texts, statement_words,
        strip_heredocs,
    )
else:
    from read_only_command import command_segments
    from shell_invocation import (
        ASSIGNMENT, command_words, invocation, segment_stages, stage_texts, statement_words,
        strip_heredocs,
    )

COMMAND_KEY_PARTS = (
    "pager", "editor", "ssh", r"alias\.", "external", "textconv", "fsmonitor", "hook", "askpass",
    r"filter\.", "program", "helper", "include", "tool", "cmd", "command", "gitproxy",
    "worktree", "attributes", "protocol",
)
COMMAND_KEYS = re.compile("|".join(COMMAND_KEY_PARTS), re.IGNORECASE)
COMMAND_ENVIRONMENT = re.compile(
    r"GIT_(?:PAGER|EDITOR|SEQUENCE_EDITOR|SSH|SSH_COMMAND|EXTERNAL_DIFF|ASKPASS|PROXY_COMMAND"
    r"|CONFIG\w*|EXEC_PATH|TEMPLATE_DIR)="
)
VALUED_GLOBALS = frozenset({"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"})
REMOTE_COMMANDS = frozenset({"fetch", "clone", "ls-remote", "pull", "push", "archive", "submodule"})
REMOTE_PROGRAM_OPTIONS = ("--upload-pack", "--receive-pack", "--exec")
SHORT_UPLOAD_PACK = "-u"
SHORT_UPLOAD_COMMANDS = frozenset({"clone", "ls-remote"})
WORK_TREE_OPTION = "--work-tree"
WORK_TREE_VARIABLE = "GIT_WORK_TREE="
PAGER_OPTIONS = ("--open-files-in-pager", "-O")
TREE_MUTATIONS = frozenset({
    "reset", "checkout", "switch", "restore", "stash", "apply", "am", "merge", "pull", "rebase",
    "clean", "cherry-pick", "revert", "rm", "mv", "read-tree", "checkout-index",
    "sparse-checkout", "bisect", "filter-branch", "submodule",
})
TREE_RESETS = frozenset({"--hard", "--merge", "--keep"})
BRANCH_CREATION = frozenset({"-b", "-B", "-c", "-C"})
STASH_READS = frozenset({"list", "show"})
BISECT_READS = frozenset({"log", "view", "visualize", "terms"})
APPLY_READS = frozenset({"--check", "--stat", "--numstat", "--summary", "--cached"})
SUBMODULE_MUTATIONS = frozenset({"update", "deinit", "absorbgitdirs"})
CONFIG_READS = frozenset({
    "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
    "--show-origin", "--show-scope", "get", "list",
})
CONFIG_EDITS = frozenset({"-e", "--edit", "edit"})
MESSAGE_COMMANDS = frozenset({"commit", "tag", "notes", "merge", "revert", "stash"})
MESSAGE_OPTIONS = frozenset({"-m", "--message", "-F", "--file"})
INLINE_DEPTH = 3
AWK_QUOTES = str.maketrans("", "", "'\"")


class GitCall(NamedTuple):
    environment: tuple[str, ...]
    settings: tuple[str, ...]
    subcommand: Optional[str]
    args: tuple[str, ...]
    work_trees: tuple[str, ...] = ()

    @property
    def operands(self) -> tuple[str, ...]:
        return tuple(arg for arg in self.args if not arg.startswith("-"))

    def has_short(self, letter: str) -> bool:
        return any(
            arg.startswith("-") and not arg.startswith("--") and letter in arg[1:]
            for arg in self.args
        )


class GlobalOptions(NamedTuple):
    settings: tuple[str, ...]
    work_trees: tuple[str, ...]
    length: int


def _option_value(args: list[str], index: int) -> str:
    return args[index + 1] if index + 1 < len(args) else ""


def _globals(args: list[str]) -> GlobalOptions:
    settings: list[str] = []
    work_trees: list[str] = []
    index = 0
    while index < len(args) and args[index].startswith("-"):
        flag, _, attached = args[index].partition("=")
        valued = flag in ("-c", "--config-env") or flag in VALUED_GLOBALS
        value = attached or (_option_value(args, index) if valued else "")
        if flag in ("-c", "--config-env"):
            settings.append(value)
        if flag == WORK_TREE_OPTION:
            work_trees.append(value)
        index += 2 if valued and not attached else 1
    return GlobalOptions(tuple(settings), tuple(work_trees), index)


def git_call(words: list[str]) -> Optional[GitCall]:
    call = invocation(words)
    if call is None or call.target is None or os.path.basename(call.target) != "git":
        return None
    start = words.index(call.target)
    environment = tuple(word for word in words[:start] if ASSIGNMENT.fullmatch(word))
    options = _globals(words[start + 1 :])
    rest = words[start + 1 + options.length :]
    variable_trees = tuple(
        word.partition("=")[2] for word in environment if word.startswith(WORK_TREE_VARIABLE)
    )
    subcommand = rest[0] if rest else None
    work_trees = options.work_trees + variable_trees
    return GitCall(environment, options.settings, subcommand, tuple(rest[1:]), work_trees)


def _statement_lists(segment: str) -> list[list[str]]:
    stages = segment_stages(segment)
    if stages is None:
        return statement_words(segment)
    return [stage_texts(stage) for stage in stages]


def git_calls(command: str, depth: int = 0) -> list[GitCall]:
    calls: list[GitCall] = []
    for segment in command_segments(command):
        for words in _statement_lists(segment):
            found = git_call(words)
            if found is not None:
                calls.append(found)
            inner = invocation(words)
            if inner is not None and inner.code and depth < INLINE_DEPTH:
                code = inner.code.translate(AWK_QUOTES) if inner.family == "awk" else inner.code
                calls.extend(git_calls(code, depth + 1))
    return calls


def _config_writes_commands(args: tuple[str, ...]) -> bool:
    if any(arg in CONFIG_READS for arg in args):
        return False
    if any(arg in CONFIG_EDITS for arg in args):
        return True
    keys = [arg for arg in args if not arg.startswith("-") and arg != "set"]
    return bool(keys) and bool(COMMAND_KEYS.search(keys[0]))


def _starts_with_option(args: tuple[str, ...], names: tuple[str, ...]) -> bool:
    return any(arg == name or arg.startswith(name + "=") for arg in args for name in names)


def _opens_pager(call: GitCall) -> bool:
    return _starts_with_option(call.args, PAGER_OPTIONS[:1]) or call.has_short("O")


def _bisect_runs(call: GitCall) -> bool:
    return call.args[:1] == ("run",)


def _submodule_runs(call: GitCall) -> bool:
    return "foreach" in call.args


def _filter_runs(call: GitCall) -> bool:
    return any(arg.partition("=")[0].endswith("-filter") for arg in call.args)


PROGRAM_RUNNERS = {
    "grep": _opens_pager,
    "bisect": _bisect_runs,
    "submodule": _submodule_runs,
    "filter-branch": _filter_runs,
}


def _runs_program_option(call: GitCall) -> bool:
    remote = call.subcommand in REMOTE_COMMANDS
    if remote and _starts_with_option(call.args, REMOTE_PROGRAM_OPTIONS):
        return True
    if call.subcommand in SHORT_UPLOAD_COMMANDS and SHORT_UPLOAD_PACK in call.args:
        return True
    check = PROGRAM_RUNNERS.get(call.subcommand or "")
    return check is not None and check(call)


def runs_commands(call: GitCall) -> bool:
    if any(COMMAND_ENVIRONMENT.match(assignment) for assignment in call.environment):
        return True
    if any(COMMAND_KEYS.search(setting.split("=", 1)[0]) for setting in call.settings):
        return True
    if call.subcommand == "config" and _config_writes_commands(call.args):
        return True
    return _runs_program_option(call)


def sets_command_environment(command: str) -> bool:
    words = (word for statement in statement_words(command) for word in statement)
    return any(COMMAND_ENVIRONMENT.match(word) for word in words)


def _resets_index_only(call: GitCall) -> bool:
    return not TREE_RESETS.intersection(call.args)


def _creates_branch(call: GitCall) -> bool:
    return bool(call.args) and call.args[0] in BRANCH_CREATION


def _cleans_dry(call: GitCall) -> bool:
    return "--dry-run" in call.args or call.has_short("n")


def _applies_nothing(call: GitCall) -> bool:
    return bool(APPLY_READS.intersection(call.args)) and "--apply" not in call.args


def _removes_from_index(call: GitCall) -> bool:
    return "--cached" in call.args


def _reads_tree_into_index(call: GitCall) -> bool:
    return not call.has_short("u")


TREE_KEEPERS = {
    "reset": _resets_index_only,
    "checkout": _creates_branch,
    "switch": _creates_branch,
    "clean": _cleans_dry,
    "apply": _applies_nothing,
    "rm": _removes_from_index,
    "read-tree": _reads_tree_into_index,
}


def _keeps_tree(call: GitCall) -> bool:
    keeper = TREE_KEEPERS.get(call.subcommand or "")
    return keeper is not None and keeper(call)


def _reads_only(call: GitCall) -> bool:
    first = call.args[0] if call.args else None
    readers = {
        "stash": STASH_READS, "bisect": BISECT_READS, "sparse-checkout": frozenset({"list"}),
    }
    if call.subcommand in readers:
        return first in readers[call.subcommand]
    if call.subcommand == "submodule":
        return first not in SUBMODULE_MUTATIONS
    return False


def mutates_tree(call: GitCall) -> bool:
    if call.subcommand not in TREE_MUTATIONS:
        return False
    return not (_keeps_tree(call) or _reads_only(call))


def _takes_message(word: str) -> bool:
    cluster = word.startswith("-") and not word.startswith("--") and word[-1:] in ("m", "F")
    return word in MESSAGE_OPTIONS or cluster


def _holds_message(word: str) -> bool:
    attached = word[:2] in ("-m", "-F") and len(word) > 2
    return word.startswith(("--message=", "--file=")) or attached


def _message_values(words: list[str]) -> set[int]:
    skipped: set[int] = set()
    for index, word in enumerate(words):
        if _takes_message(word):
            skipped.update({index, index + 1})
        elif _holds_message(word):
            skipped.add(index)
    return skipped


def message_free_words(segment: str) -> Optional[list[str]]:
    statements = statement_words(segment)
    call = git_call(statements[0]) if statements else None
    if call is None or call.subcommand not in MESSAGE_COMMANDS:
        return None
    words = command_words(strip_heredocs(segment))
    skipped = _message_values(words)
    return [word for index, word in enumerate(words) if index not in skipped]
