from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path
from typing import Iterator, NamedTuple

try:
    from .tmux_git_policy import SHELLS, command_segments, expansion_source, unwrap
except ImportError:
    from tmux_git_policy import SHELLS, command_segments, expansion_source, unwrap

COMMIT_WRAPPERS = {"env", "command", "exec", "sudo", "time", "nohup", "timeout", "xargs"}
COMPOUND_KEYWORDS = {"{", "}", "!", "if", "then", "do", "else", "elif", "while", "until"}
VALUED_GIT_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELL_COMMAND_FLAG = re.compile(r"^-[a-zA-Z]*c$")
SUBSTITUTIONS = (re.compile(r"\$\(([^()]*)\)"), re.compile(r"`([^`]*)`"))
CONVENTIONAL_SUBJECT = re.compile(r"^(feat|fix|test|refactor|perf|docs|style|chore)\(.+\): .+")
SHORT_MESSAGE = re.compile(r"^-[a-zA-Z]*m(.*)$")
HEREDOC_START = re.compile(r"^\$\(cat <<-?\s*['\"]?(\w+)")


class CommitCall(NamedTuple):
    segment: list[str]
    arguments: list[str]


def command_words(tokens: list[str]) -> list[str]:
    index = 0
    while index < len(tokens) and (ASSIGNMENT.match(tokens[index]) or tokens[index] in COMPOUND_KEYWORDS):
        index += 1
    return tokens[index:]


def git_subcommand_arguments(args: list[str]) -> list[str]:
    remaining = list(args)
    while remaining and remaining[0].startswith("-"):
        option = remaining.pop(0)
        if option in VALUED_GIT_OPTIONS and remaining:
            remaining.pop(0)
    return remaining


def shell_body(args: list[str]) -> str | None:
    for index, token in enumerate(args[:-1]):
        if SHELL_COMMAND_FLAG.match(token):
            return args[index + 1]
    return None


def wrapped_arguments(name: str, args: list[str]) -> list[str]:
    unwrapped = unwrap(args, name)
    return unwrapped[1:] if name == "timeout" else unwrapped


def commit_arguments(tokens: list[str]) -> list[str] | None:
    words = command_words(tokens)
    if not words:
        return None
    name, args = Path(words[0]).name, words[1:]
    if name == "git":
        subcommand = git_subcommand_arguments(args)
        return subcommand[1:] if subcommand[:1] == ["commit"] else None
    if name in COMMIT_WRAPPERS:
        return commit_arguments(wrapped_arguments(name, args))
    if name in SHELLS:
        body = shell_body(args)
        call = None if body is None else find_commit(body)
        return None if call is None else call.arguments
    return None


def candidate_sources(command: str) -> Iterator[str]:
    joined = command.replace("\\\n", "")
    yield joined
    source = expansion_source(joined)
    for pattern in SUBSTITUTIONS:
        yield from pattern.findall(source)


def find_commit(command: str) -> CommitCall | None:
    for source in candidate_sources(command):
        for segment in command_segments(source):
            arguments = commit_arguments(segment)
            if arguments is not None:
                return CommitCall(segment, arguments)
    return None


def commit_segment(command: str) -> str | None:
    call = find_commit(command)
    return None if call is None else shlex.join(call.segment)


def heredoc_subject(value: str) -> str:
    first_line, *body = value.splitlines()
    start = HEREDOC_START.match(first_line)
    terminator = start.group(1) if start else ""
    lines = [line.strip() for line in body if line.strip() and line.strip() != terminator]
    conventional = [line for line in lines if CONVENTIONAL_SUBJECT.match(line)]
    return (conventional or lines or [""])[0]


def message_subject(value: str) -> str:
    if HEREDOC_START.match(value):
        return heredoc_subject(value)
    return value.split("\n", 1)[0]


def file_subject(name: str, cwd: str) -> str:
    if name == "-":
        return ""
    path = Path(cwd) / name if cwd else Path(name)
    if not path.is_file():
        return ""
    return path.read_text(errors="replace").split("\n", 1)[0]


def option_value(option: str, remaining: list[str]) -> tuple[str, str] | None:
    if option in {"--message", "--file", "-F"}:
        return (option, remaining.pop(0)) if remaining else None
    for long_name in ("--message", "--file"):
        if option.startswith(long_name + "="):
            return long_name, option.partition("=")[2]
    if option.startswith("-F") and not option.startswith("--"):
        return "-F", option[2:]
    short = SHORT_MESSAGE.match(option)
    if short is None or option.startswith("--"):
        return None
    if short.group(1):
        return "-m", short.group(1)
    return ("-m", remaining.pop(0)) if remaining else None


def commit_subject(arguments: list[str], cwd: str) -> str:
    remaining = list(arguments)
    while remaining:
        found = option_value(remaining.pop(0), remaining)
        if found is None:
            continue
        kind, value = found
        return file_subject(value, cwd) if kind in {"-F", "--file"} else message_subject(value)
    return ""


def nonconforming_subject(command: str, cwd: str) -> str | None:
    call = find_commit(command)
    if call is None:
        return None
    subject = commit_subject(call.arguments, cwd)
    if not subject or CONVENTIONAL_SUBJECT.match(subject):
        return None
    return subject


def main(argv: list[str]) -> int:
    subject = nonconforming_subject(sys.stdin.read(), argv[1] if len(argv) > 1 else "")
    if subject is None:
        return 1
    print(subject)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
