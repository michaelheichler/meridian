from __future__ import annotations

import re
import sys
from collections.abc import Iterator
from pathlib import Path

try:
    from .tmux_git_policy import SHELLS, command_segments, expansion_source, unwrap
except ImportError:
    from tmux_git_policy import SHELLS, command_segments, expansion_source, unwrap

COMMIT_WRAPPERS = {"env", "command", "exec", "sudo", "time", "nohup", "timeout", "xargs"}
COMPOUND_KEYWORDS = {"{", "}", "!", "if", "then", "do", "else", "elif", "while", "until"}
VALUED_GIT_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
VALUED_COMMIT_OPTIONS = {
    "--trailer", "--author", "--date", "-C", "-c", "-t", "--template", "--cleanup", "--fixup",
    "--squash", "--reuse-message", "--reedit-message", "--pathspec-from-file",
}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELL_COMMAND_FLAG = re.compile(r"^-[a-zA-Z]*c$")
SUBSTITUTIONS = (re.compile(r"\$\(([^()]*)\)"), re.compile(r"`([^`]*)`"))
CONVENTIONAL_SUBJECT = re.compile(r"^(feat|fix|test|refactor|perf|docs|style|chore)\(.+\): .+")
SHORT_MESSAGE = re.compile(r"^-[asnveSq]*m(.*)$")
SHORT_FILE = re.compile(r"^-[asnveSq]*F(.*)$")
HEREDOC_START = re.compile(r"^\$\(cat <<-?\s*['\"]?(\w+)")
HEREDOC_OPERATOR = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")


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


def commit_arguments(tokens: list[str]) -> Iterator[list[str]]:
    words = command_words(tokens)
    if not words:
        return
    name, args = Path(words[0]).name, words[1:]
    if name == "git":
        subcommand = git_subcommand_arguments(args)
        if subcommand[:1] == ["commit"]:
            yield subcommand[1:]
    elif name in COMMIT_WRAPPERS:
        yield from commit_arguments(wrapped_arguments(name, args))
    elif name in SHELLS:
        body = shell_body(args)
        if body is not None:
            yield from commit_calls(body)


def heredoc_body_end(command: str, start: int, terminator: str) -> int:
    position = start
    while position < len(command):
        line_end = command.find("\n", position)
        next_line = len(command) if line_end == -1 else line_end + 1
        if command[position:next_line].strip() == terminator:
            return next_line
        position = next_line
    return position


def without_heredoc_bodies(command: str) -> str:
    kept: list[str] = []
    quote, terminators, index = "", [], 0
    while index < len(command):
        character = command[index]
        operator = None if quote else HEREDOC_OPERATOR.match(command, index)
        if character == "\n" and not quote and terminators:
            kept.append(character)
            index = index + 1
            while terminators:
                index = heredoc_body_end(command, index, terminators.pop(0))
            continue
        if character == "\\" and quote != "'":
            kept.append(command[index:index + 2])
            index += 2
            continue
        if operator is not None and not command.startswith("<<<", index):
            terminators.append(operator.group(1))
            kept.append(operator.group(0))
            index = operator.end()
            continue
        if character in "'\"" and quote in ("", character):
            quote = "" if quote else character
        kept.append(character)
        index += 1
    return "".join(kept)


def candidate_sources(command: str) -> Iterator[str]:
    joined = without_heredoc_bodies(command.replace("\\\n", ""))
    yield joined
    source = expansion_source(joined)
    for pattern in SUBSTITUTIONS:
        yield from pattern.findall(source)


def commit_calls(command: str) -> Iterator[list[str]]:
    for source in candidate_sources(command):
        for segment in command_segments(source):
            yield from commit_arguments(segment)


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
    if value.startswith("$") or value == "{}":
        return ""
    return value.split("\n", 1)[0]


def file_subject(name: str, cwd: str) -> str:
    if name == "-" or name.startswith("$") or name == "{}":
        return ""
    path = Path(cwd) / name if cwd else Path(name)
    if not path.is_file():
        return ""
    with path.open(errors="replace") as message_file:
        return message_file.readline().rstrip("\n")


def separate_value(kind: str, attached: str, remaining: list[str]) -> tuple[str, str] | None:
    if attached:
        return kind, attached
    return (kind, remaining.pop(0)) if remaining else None


def message_option(option: str, remaining: list[str]) -> tuple[str, str] | None:
    for long_name, kind in (("--message", "-m"), ("--file", "-F")):
        if option == long_name:
            return separate_value(kind, "", remaining)
        if option.startswith(long_name + "="):
            return kind, option.partition("=")[2]
    if option.startswith("--"):
        return None
    for pattern, kind in ((SHORT_MESSAGE, "-m"), (SHORT_FILE, "-F")):
        short = pattern.match(option)
        if short is not None:
            return separate_value(kind, short.group(1), remaining)
    return None


def commit_subject(arguments: list[str], cwd: str) -> str:
    remaining = list(arguments)
    while remaining:
        option = remaining.pop(0)
        if option == "--":
            break
        if option in VALUED_COMMIT_OPTIONS:
            remaining = remaining[1:]
            continue
        found = message_option(option, remaining)
        if found is not None:
            kind, value = found
            return file_subject(value, cwd) if kind == "-F" else message_subject(value)
    return ""


def nonconforming_subject(command: str, cwd: str) -> str | None:
    for arguments in commit_calls(command):
        subject = commit_subject(arguments, cwd)
        if subject and not CONVENTIONAL_SUBJECT.match(subject):
            return subject
    return None


def main(argv: list[str]) -> int:
    subject = nonconforming_subject(sys.stdin.read(), argv[1] if len(argv) > 1 else "")
    if subject is None:
        return 1
    print(subject)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
