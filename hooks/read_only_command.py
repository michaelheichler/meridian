from __future__ import annotations

import os
import re
import shlex
from itertools import takewhile
from typing import NamedTuple, Optional

OPERATOR_CHARS = frozenset("();<>|&")
RAW_FORBIDDEN = re.compile(r"\$\(|`|[\n\r<{\u0080-\U0010ffff]|(?:^|[\s|=])\$['\"]")
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
    "ls": Spec("lahA1dtrS", {}, frozenset(), False, True),
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
FIND_FLAGS = frozenset({
    "-H", "-L", "-P", "-print", "-print0", "-empty", "-readable", "-writable",
    "-executable", "-prune", "-not", "!", "-a", "-and", "-o", "-or",
})
FIND_VALUES = {
    "-name": ANY_TEXT, "-iname": ANY_TEXT, "-path": ANY_TEXT, "-ipath": ANY_TEXT,
    "-type": re.compile(r"[bcdflps]"), "-maxdepth": COUNT, "-mindepth": COUNT,
}
FIRST_STAGE = frozenset({"cat", "grep", "head", "tail", "wc", "ls", "stat"})
PIPE_STAGE = frozenset({"grep", "head", "tail", "wc", "sort", "uniq", "cut"})


def _tokenize(command: str) -> Optional[list[str]]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        return list(lexer)
    except ValueError:
        return None


def _is_operator(token: str) -> bool:
    return all(char in OPERATOR_CHARS for char in token) and token != "|"


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


def _first_stage_ok(stage: list[str], cwd: str) -> bool:
    if stage[0] == "sed":
        return _sed_ok(stage)
    return stage[0] in FIRST_STAGE and _command_safe(stage, cwd)


def _pipe_stage_ok(stage: list[str], cwd: str) -> bool:
    return stage[0] in PIPE_STAGE and _command_safe(stage, cwd)


def _split_stages(tokens: list[str]) -> list[list[str]]:
    stages: list[list[str]] = [[]]
    for token in tokens:
        if token == "|":
            stages.append([])
        else:
            stages[-1].append(token)
    return stages


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


def is_source_inspection(command: str, cwd: str) -> bool:
    """Wider than is_plain_read_command, because agents must search hook sources while pending-work reads stay narrow."""
    if is_plain_read_command(command, cwd):
        return True
    if RAW_FORBIDDEN.search(command):
        return False
    tokens = _tokenize(command)
    if not tokens or any(token == "|" or _is_operator(token) for token in tokens):
        return False
    if tokens[0] == "find":
        return _find_read_only(tokens[1:])
    return _flags_allowed(tokens, INSPECTION_SPECS)


def is_plain_read_command(command: str, cwd: str) -> bool:
    if not isinstance(command, str) or RAW_FORBIDDEN.search(command):
        return False
    tokens = _tokenize(command)
    if not tokens or any(_is_operator(token) for token in tokens):
        return False
    stages = _split_stages(tokens)
    if not all(stages):
        return False
    later = stages[1:]
    return _first_stage_ok(stages[0], cwd) and all(
        _pipe_stage_ok(item, cwd) for item in later
    )
