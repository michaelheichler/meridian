from __future__ import annotations

import re
import shlex
import sys

try:
    from .tmux_git_policy import command_segments, unwrap
except ImportError:
    from tmux_git_policy import command_segments, unwrap

COMMIT_WRAPPERS = {"env", "command", "exec", "sudo", "time", "nohup", "timeout"}
VALUED_GIT_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def without_assignments(tokens: list[str]) -> list[str]:
    index = 0
    while index < len(tokens) and ASSIGNMENT.match(tokens[index]):
        index += 1
    return tokens[index:]


def git_subcommand_arguments(args: list[str]) -> list[str]:
    remaining = list(args)
    while remaining and remaining[0].startswith("-"):
        option = remaining.pop(0)
        if option in VALUED_GIT_OPTIONS and remaining:
            remaining.pop(0)
    return remaining


def is_commit_invocation(tokens: list[str]) -> bool:
    words = without_assignments(tokens)
    if not words:
        return False
    name, args = words[0], words[1:]
    if name == "git":
        subcommand = git_subcommand_arguments(args)
        return bool(subcommand) and subcommand[0] == "commit"
    if name in COMMIT_WRAPPERS:
        unwrapped = unwrap(args, name)
        if name == "timeout":
            unwrapped = unwrapped[1:]
        return is_commit_invocation(unwrapped)
    return False


def commit_segment(command: str) -> str | None:
    for segment in command_segments(command):
        if is_commit_invocation(segment):
            return shlex.join(segment)
    return None


def main() -> int:
    segment = commit_segment(sys.stdin.read())
    if segment is None:
        return 1
    print(segment)
    return 0


if __name__ == "__main__":
    sys.exit(main())
