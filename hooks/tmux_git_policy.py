from pathlib import Path
import re
import shlex

READ_COMMANDS = {"status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "help", "version"}
READ_OPTIONS = {"--no-pager", "--paginate", "--literal-pathspecs", "--no-optional-locks"}
PATH_OPTIONS = {"-C", "--git-dir", "--work-tree"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def consume_option(args) -> bool:
    option = args.pop(0)
    if option in PATH_OPTIONS and args:
        args.pop(0)
        return True
    return option in READ_OPTIONS


def git_arguments_write(args) -> bool:
    args = list(args)
    while args and args[0].startswith("-"):
        if not consume_option(args):
            return True
    if not args:
        return False
    subcommand, tail = args[0], args[1:]
    if subcommand in READ_COMMANDS:
        return False
    if subcommand == "config":
        return not config_read(tail)
    if subcommand == "branch":
        return any(arg not in {"--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--show-current"} for arg in tail)
    return not (subcommand == "worktree" and tail and tail[0] == "list")


def config_read(args) -> bool:
    reads = {"--get", "--get-all", "--get-regexp", "--list", "-l"}
    options = reads | {"--global", "--local", "--system", "--show-origin", "--show-scope", "--includes", "--null", "-z"}
    return bool(set(args) & reads) and all(not arg.startswith("-") or arg in options for arg in args)


def shell_body_writes(tokens) -> bool:
    for index, token in enumerate(tokens[:-1]):
        if not re.fullmatch(r"-[a-zA-Z]*c", token):
            continue
        body = tokens[index + 1:]
        if body[0] == "--":
            body = body[1:]
        return bool(body) and git_write(body[0].lstrip("$"))
    return False


def env_body_writes(tokens) -> bool:
    for index, token in enumerate(tokens):
        if token in {"-S", "--split-string"} and index + 1 < len(tokens):
            return git_write(tokens[index + 1])
        if token.startswith("--split-string="):
            return git_write(token.partition("=")[2])
        if token.startswith("-S") and len(token) > 2:
            return git_write(token[2:])
    return False


def command_tokens(command) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>\n")
    lexer.whitespace_split = True
    return list(lexer)


def git_tail(tokens, index) -> list[str]:
    tail = []
    for token in tokens[index + 1:]:
        if token and all(char in ";&|()<>\n" for char in token):
            break
        tail.append(token)
    return tail


def git_write(command) -> bool:
    try:
        tokens = command_tokens(command)
    except ValueError:
        return True
    for index, token in enumerate(tokens):
        name = Path(token.strip("`").lstrip("$")).name
        if name == "env" and env_body_writes(git_tail(tokens, index)):
            return True
        if name in SHELLS and shell_body_writes(git_tail(tokens, index)):
            return True
        if name == "git" and git_arguments_write(git_tail(tokens, index)):
            return True
    return False
