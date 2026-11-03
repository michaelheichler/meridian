from __future__ import annotations

from pathlib import Path
from typing import Iterator
import re
import shlex

READ_COMMANDS = {
    "status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "help", "version",
    "ls-remote", "describe", "cat-file", "shortlog", "for-each-ref", "merge-base", "rev-list",
    "grep", "show-ref", "name-rev",
}
READ_OPTIONS = {"--no-pager", "--paginate", "--literal-pathspecs", "--no-optional-locks"}
PATH_OPTIONS = {"-C", "--git-dir", "--work-tree", "-c"}
SHELLS = {"bash", "sh", "zsh", "fish", "csh", "tcsh", "ksh", "dash", "script"}
WRAPPERS = {"env", "command", "xargs", "exec", "sudo", "time", "nohup", "timeout"}
OPTION_VALUES = {
    "env": {"-u", "--unset", "-C", "--chdir"},
    "xargs": {"-I", "-n", "-L", "-P", "-E", "-a", "--arg-file", "--max-args", "--max-lines", "--max-procs", "--replace"},
    "exec": {"-a"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-T", "--user", "--group", "--host", "--prompt"},
    "time": {"-f", "-o", "--format", "--output"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
}


def consume_option(args) -> bool:
    option = args.pop(0)
    if option in PATH_OPTIONS and args:
        args.pop(0)
        return True
    return option in READ_OPTIONS or option.startswith(("--git-dir=", "--work-tree="))


def config_read(args) -> bool:
    reads = {"--get", "--get-all", "--get-regexp", "--list", "-l"}
    options = reads | {"--global", "--local", "--system", "--show-origin", "--show-scope", "--includes", "--null", "-z"}
    return bool(set(args) & reads) and all(not arg.startswith("-") or arg in options for arg in args)


def branch_read(args) -> bool:
    options = {"--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--show-current"}
    if args and args[0] in {"--contains", "--no-contains", "--merged", "--no-merged"}:
        return len(args) <= 2
    return all(arg in options for arg in args)


def conditional_read(subcommand, args) -> bool:
    if subcommand == "config":
        return config_read(args)
    if subcommand == "branch":
        return branch_read(args)
    if subcommand == "symbolic-ref":
        return len([arg for arg in args if not arg.startswith("-")]) == 1 and not set(args) & {"--delete", "-d"}
    if subcommand == "remote":
        return all(arg in {"-v", "--verbose"} for arg in args)
    if subcommand == "tag":
        return bool(args) and args[0] in {"--list", "-l"}
    if subcommand == "reflog":
        return not args or args[0] == "show" or args[0].startswith("-")
    reads = {"worktree": "list", "stash": "list"}
    return bool(args) and args[0] == reads.get(subcommand)


def git_arguments_write(args) -> bool:
    args = list(args)
    while args and args[0].startswith("-"):
        if not consume_option(args):
            return True
    if not args:
        return False
    subcommand, tail = args[0], args[1:]
    return subcommand not in READ_COMMANDS and not conditional_read(subcommand, tail)


def shell_body_writes(tokens) -> bool:
    for index, token in enumerate(tokens[:-1]):
        if not (re.fullmatch(r"-[a-zA-Z]*c", token) or token == "--command"):
            continue
        body = tokens[index + 1:]
        if body[0] == "--":
            body = body[1:]
        return bool(body) and git_write(body[0].lstrip("$"))
    return not any(token and not token.startswith("-") for token in tokens if token not in {"<", "<<", "<<<"}) or any("<" in token for token in tokens)


def env_body(tokens) -> str | None:
    for index, token in enumerate(tokens):
        if token in {"-S", "--split-string"} and index + 1 < len(tokens):
            return tokens[index + 1] + " " + shlex.join(tokens[index + 2:])
        if token.startswith("--split-string="):
            return token.partition("=")[2] + " " + shlex.join(tokens[index + 1:])
        if token.startswith("-S") and len(token) > 2:
            return token[2:] + " " + shlex.join(tokens[index + 1:])
    return None


def command_tokens(command) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    return list(lexer)


def unwrap(tokens, wrapper) -> list[str]:
    args = list(tokens)
    while args and (args[0].startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", args[0])):
        option = args.pop(0)
        if option in OPTION_VALUES.get(wrapper, set()) and args:
            args.pop(0)
    return args


def wrapper_writes(name, args) -> bool:
    body = env_body(args) if name == "env" else None
    if body is not None:
        return git_write(body)
    if name == "command" and set(args) & {"-v", "-V"}:
        return False
    args = unwrap(args, name)
    if name == "timeout" and args:
        args = args[1:]
    return segment_writes(args)


def segment_writes(tokens) -> bool:
    tokens = list(tokens)
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        tokens.pop(0)
    if not tokens:
        return False
    name, args = Path(tokens[0].strip("`").lstrip("$")).name, tokens[1:]
    if name == "git":
        return git_arguments_write(args)
    if name.startswith("git-"):
        return git_arguments_write([name[4:]] + args)
    if name in SHELLS:
        return shell_body_writes(args)
    if name == "eval":
        return git_write(" ".join(args))
    return name in WRAPPERS and wrapper_writes(name, args)


def expansion_source(command) -> str:
    output, quote, escaped = [], "", False
    for character in command:
        if escaped:
            output.append(" ")
            escaped = False
            continue
        if character == "\\" and quote != "'":
            escaped = True
            output.append(" ")
            continue
        if character == "'" and quote != '"':
            quote = "" if quote else "'"
            output.append(" ")
            continue
        if character == '"' and quote != "'":
            quote = "" if quote else '"'
        output.append(" " if quote == "'" else character)
    return "".join(output)


def substitutions_write(command) -> bool:
    patterns = (r"\$\(([^()]*)\)", r"`([^`]*)`")
    source = expansion_source(command)
    return any(git_write(body) for pattern in patterns for body in re.findall(pattern, source))


def git_write(command) -> bool:
    if not isinstance(command, str):
        raise TypeError("Bash command must be a string")
    if substitutions_write(command):
        return True
    return any(segment_writes(segment) for segment in command_segments(command))


def command_segments(command) -> Iterator[list[str]]:
    segment = []
    for token in command_tokens(command):
        if token == "-exec" or (token and all(char in ";&|()\n" for char in token)):
            yield segment
            segment = []
            continue
        segment.append(token)
    yield segment
