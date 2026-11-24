from __future__ import annotations

import os
import re
import shlex
from itertools import takewhile
from typing import Callable, NamedTuple, Optional

SED_ADDRESS = r"(?:\d+|\$|/[^/\\]*/)"
SED_SCRIPT = re.compile(rf"(?:{SED_ADDRESS}(?:,{SED_ADDRESS})?)?p")
SED_FLAGS = frozenset({"-n", "-E", "-r", "--quiet", "--silent", "--regexp-extended"})
SED_QUIET = frozenset({"-n", "--quiet", "--silent"})
NUMBER = re.compile(r"[+-]?\d+")
COUNT = re.compile(r"\d+")
ANY_TEXT = re.compile(r".+")
ONE_CHAR = re.compile(r".")
FIELD_LIST = re.compile(r"[\d,\-]+")
SORT_KEY = re.compile(r"\d+(?:,\d+)?")
DIGIT_FLAG = re.compile(r"-\d+")
AWK_UNSAFE = re.compile(r"system|getline|[|>]")
AWK_VALUED = ("-F", "-v")


class Spec(NamedTuple):
    noarg: str
    valued: dict
    long: frozenset
    numeric: bool
    operands: bool


SPECS = {
    "cat": Spec("nbsvetA", {}, frozenset(), False, True),
    "head": Spec("q", {"n": NUMBER, "c": NUMBER}, frozenset(), True, True),
    "tail": Spec("q", {"n": NUMBER, "c": NUMBER}, frozenset(), True, True),
    "wc": Spec("lwcm", {}, frozenset(), False, True),
    "stat": Spec("L", {}, frozenset(), False, True),
    "grep": Spec(
        "nivclLwxEFohHsq",
        {"e": ANY_TEXT, "m": COUNT, "A": COUNT, "B": COUNT, "C": COUNT},
        frozenset({"--color=never"}),
        False,
        True,
    ),
    "sort": Spec("nru", {"k": SORT_KEY, "t": ONE_CHAR}, frozenset(), False, True),
    "uniq": Spec("cdu", {}, frozenset(), False, False),
    "cut": Spec("", {"d": ONE_CHAR, "f": FIELD_LIST, "c": FIELD_LIST}, frozenset(), False, True),
    "pwd": Spec("LP", {}, frozenset(), False, False),
    "cd": Spec("LP", {}, frozenset(), False, True),
    "pushd": Spec("", {}, frozenset(), False, True),
    "jq": Spec(
        "rcesnSjaMCR",
        {},
        frozenset({
            "--raw-output", "--compact-output", "--slurp", "--null-input", "--sort-keys",
            "--exit-status", "--tab", "--join-output", "--raw-input",
        }),
        False,
        True,
    ),
    "diff": Spec(
        "uqrNbwBiE",
        {"U": COUNT},
        frozenset({"--brief", "--recursive", "--new-file", "--ignore-all-space", "--color=never"}),
        False,
        True,
    ),
}
INSPECTION_SPECS = {
    "grep": Spec(
        "nivclLwxEFohHsqrR",
        {"e": ANY_TEXT, "m": COUNT, "A": COUNT, "B": COUNT, "C": COUNT},
        frozenset({"--color=never", "--recursive", "--line-number", "--ignore-case"}),
        False,
        True,
    ),
    "rg": Spec(
        "nivclLwxFohHsquUS",
        {
            "e": ANY_TEXT, "m": COUNT, "A": COUNT, "B": COUNT, "C": COUNT,
            "g": ANY_TEXT, "t": ANY_TEXT, "T": ANY_TEXT,
        },
        frozenset({
            "--files", "--hidden", "--no-ignore", "--line-number", "--ignore-case",
            "--fixed-strings", "--count", "--files-with-matches", "--color=never",
        }),
        False,
        True,
    ),
}
GIT_INSPECTION_SPECS = {
    "ls-files": Spec("ztv", {}, frozenset({"--cached", "--stage", "--others", "--exclude-standard"}), False, True),
    "log": Spec("p", {}, frozenset({"--oneline", "--stat", "--name-only", "--name-status", "--no-patch"}), False, True),
    "show": Spec("p", {}, frozenset({"--oneline", "--stat", "--name-only", "--name-status", "--no-patch"}), False, True),
    "status": Spec("sbz", {}, frozenset({"--short", "--branch", "--porcelain", "--ignored"}), False, True),
    "diff": Spec("p", {}, frozenset({
        "--name-only", "--name-status", "--stat", "--numstat", "--shortstat", "--summary",
        "--cached", "--staged", "--check", "--no-ext-diff", "--no-textconv",
    }), False, True),
    "grep": Spec("nilrzclwFEGP", {}, frozenset({
        "--cached", "--line-number", "--ignore-case", "--fixed-strings", "--count",
        "--files-with-matches", "--full-name", "--recurse-submodules",
    }), False, True),
    "rev-parse": Spec("", {}, frozenset({
        "--show-toplevel", "--show-prefix", "--show-cdup", "--git-dir", "--absolute-git-dir",
        "--is-inside-work-tree", "--is-inside-git-dir", "--verify", "--short",
        "--abbrev-ref", "--symbolic-full-name",
    }), False, True),
    "blame": Spec("nlpw", {}, frozenset({"--line-porcelain", "--porcelain", "--show-email"}), False, True),
}
FIND_FLAGS = frozenset({
    "-H", "-L", "-P", "-print", "-print0", "-empty", "-readable", "-writable",
    "-executable", "-prune", "-not", "!", "-a", "-and", "-o", "-or",
})
FIND_VALUES = {
    "-name": ANY_TEXT, "-iname": ANY_TEXT, "-path": ANY_TEXT, "-ipath": ANY_TEXT,
    "-type": re.compile(r"[bcdflps]"), "-maxdepth": COUNT, "-mindepth": COUNT,
}
def _short_cluster(letters: str, following: Optional[str], spec: Spec) -> Optional[int]:
    for index, char in enumerate(letters):
        if char in spec.noarg:
            continue
        pattern = spec.valued.get(char)
        if pattern is None:
            return None
        attached = letters[index + 1 :]
        if attached:
            return 1 if pattern.fullmatch(attached) else None
        return 2 if following is not None and pattern.fullmatch(following) else None
    return 1


def _consume(arg: str, following: Optional[str], spec: Spec) -> Optional[int]:
    if arg.startswith("--"):
        return 1 if arg in spec.long else None
    if spec.numeric and DIGIT_FLAG.fullmatch(arg):
        return 1
    return _short_cluster(arg[1:], following, spec)


def _step(args: list[str], index: int, spec: Spec) -> Optional[int]:
    arg = args[index]
    if arg == "-" or not arg.startswith("-"):
        return 1 if spec.operands else None
    following = args[index + 1] if index + 1 < len(args) else None
    return _consume(arg, following, spec)


def _flags_allowed(stage: list[str], specs: dict = SPECS) -> bool:
    spec = specs.get(stage[0])
    if spec is None:
        return False
    args = stage[1:]
    index = 0
    while index < len(args):
        used = _step(args, index, spec)
        if used is None:
            return False
        index += used
    return True


def _has_directory_operand(stage: list[str], cwd: str) -> bool:
    operands = [arg for arg in stage[1:] if not arg.startswith("-")]
    return any(os.path.isdir(os.path.join(cwd, arg)) for arg in operands)


def _command_safe(stage: list[str], cwd: str) -> bool:
    if not _flags_allowed(stage):
        return False
    return stage[0] != "grep" or not _has_directory_operand(stage, cwd)


def _sed_ok(stage: list[str]) -> bool:
    rest = stage[1:]
    flags = list(takewhile(lambda arg: arg.startswith("-"), rest))
    body = rest[len(flags) :]
    if not body or not SED_QUIET.intersection(flags):
        return False
    if not set(flags) <= SED_FLAGS or not SED_SCRIPT.fullmatch(body[0]):
        return False
    return not any(arg.startswith("-") for arg in body[1:])


def _find_read_only(args: list[str]) -> bool:
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in FIND_FLAGS or not arg.startswith("-"):
            index += 1
            continue
        pattern = FIND_VALUES.get(arg)
        if pattern is None or index + 1 == len(args):
            return False
        if not pattern.fullmatch(args[index + 1]):
            return False
        index += 2
    return True


def command_segments(command: str) -> list[str]:
    if "<<" in command or "#" in command:
        return [command]
    lexer = shlex.shlex(command, posix=False, punctuation_chars=";&|<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
        if any(len(shlex.split(token)) != 1 for token in tokens if token.strip("\n")):
            return [command]
    except ValueError:
        return [command]
    segments = [""]
    for token in tokens:
        punctuation = all(char in ";&|\n" for char in token)
        boundary = "|" not in token or ";" in token or "&&" in token or "||" in token
        if punctuation and boundary:
            segments.append("")
        else:
            segments[-1] += " " + token
    return segments


def is_git_inspection(words: list[str]) -> bool:
    index = 1
    while index + 1 < len(words) and words[index] == "-C":
        index += 2
    args = words[index:]
    if not args:
        return False
    boundary = args.index("--") if "--" in args else len(args)
    return _flags_allowed(args[:boundary], GIT_INSPECTION_SPECS)


def _ls_ok(stage: list[str]) -> bool:
    flags = [arg for arg in stage[1:] if arg.startswith("-")]
    short_flags = (flag for flag in flags if not flag.startswith("--"))
    return "--recursive" not in flags and not any("R" in flag for flag in short_flags)


def _awk_ok(stage: list[str]) -> bool:
    args = stage[1:]
    index = 0
    while index < len(args) and args[index].startswith("-") and args[index] != "-":
        flag = args[index]
        if flag == "--":
            index += 1
            break
        if flag not in AWK_VALUED and flag[:2] not in AWK_VALUED:
            return False
        index += 2 if flag in AWK_VALUED else 1
    return index < len(args) and not AWK_UNSAFE.search(args[index])


def _find_ok(stage: list[str]) -> bool:
    return _find_read_only(stage[1:])


def _prints_arguments(_stage: list[str]) -> bool:
    return True


STAGE_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "sed": _sed_ok,
    "awk": _awk_ok,
    "ls": _ls_ok,
    "find": _find_ok,
    "git": is_git_inspection,
    "echo": _prints_arguments,
    "printf": _prints_arguments,
}


def is_read_stage(stage: list[str], cwd: str) -> bool:
    if not stage:
        return False
    check = STAGE_CHECKS.get(stage[0])
    if check is not None:
        return check(stage)
    return _command_safe(stage, cwd) or _flags_allowed(stage, INSPECTION_SPECS)
