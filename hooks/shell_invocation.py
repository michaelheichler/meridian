from __future__ import annotations

import os
import re
import shlex
from typing import NamedTuple, Optional

if __package__:
    from .path_identity import GLOB_CHARS
else:
    from path_identity import GLOB_CHARS

SHELL_OPERATOR = re.compile(r"[();<>|&]+")
REDIRECTIONS = frozenset({">", ">>", ">|", "&>", "&>>", "<", "<>", ">&", "<&"})
DUPLICATIONS = frozenset({">&", "<&"})
DESCRIPTOR_TARGET = re.compile(r"\d+-?|-")
DESCRIPTOR_NUMBER = re.compile(r"\d+")
UNSAFE_TEXT = re.compile(r"[\n\r\u0080-\U0010ffff]")
UNQUOTED_EXPANSION = re.compile(r"[$`{\\]|^~")
QUOTED_EXPANSION = re.compile(r"[$`\\]")
GLOB_PATTERN = re.compile(f"[{re.escape(GLOB_CHARS)}]")
QUOTES = ("'", '"')
SHELL_SPLIT = re.compile(r"[\s;&|<>()]+")
QUOTE_CHARS = "$'\""
EXPANSION_CHARS = "$`{"
UNRESOLVED_CHARS = "$`"
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")
PYTHON_NAME = re.compile(r"python[0-9.]*")
WRAPPER_VALUE_FLAGS = {
    "env": frozenset({"-u", "-C", "--unset", "--chdir"}),
    "sudo": frozenset({"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U"}),
    "nohup": frozenset(),
    "time": frozenset({"-f", "-o"}),
    "command": frozenset(),
    "builtin": frozenset(),
    "exec": frozenset({"-a"}),
    "nice": frozenset({"-n"}),
    "stdbuf": frozenset({"-i", "-o", "-e"}),
    "timeout": frozenset({"-s", "-k", "--signal", "--kill-after"}),
    "xargs": frozenset({"-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s"}),
}
FAMILIES = {
    "bash": "shell", "sh": "shell", "zsh": "shell", "dash": "shell", "ksh": "shell",
    "perl": "perl", "node": "node", "ruby": "ruby", "source": "source", ".": "source",
}
INLINE_LETTERS = {
    "shell": "c", "python": "c", "perl": "eE", "node": "ep", "ruby": "e", "source": "",
}
INLINE_LONG_FLAGS = {"node": frozenset({"--eval", "--print"})}
INTERPRETER_VALUE_FLAGS = {
    "shell": frozenset({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}),
    "python": frozenset({"-W", "-X"}),
    "perl": frozenset({"-I", "-M"}),
    "node": frozenset({"-r", "--require", "--import", "--loader"}),
    "ruby": frozenset({"-I", "-r"}),
    "source": frozenset(),
}
STDIN_TARGETS = (None, "-")
TEST_RUNNER_MODULE = "unittest"
KNOWN_VARIABLES = ("CLAUDE_PLUGIN_ROOT", "HOME")


class Token(NamedTuple):
    text: str
    raw: str
    operator: bool

    @property
    def quoted(self) -> bool:
        quote = self.raw[:1]
        wrapped = len(self.raw) > 1 and self.raw.endswith(quote)
        return quote in QUOTES and wrapped and quote not in self.raw[1:-1]

    @property
    def expands(self) -> bool:
        if self.quoted:
            return self.raw.startswith('"') and bool(QUOTED_EXPANSION.search(self.text))
        return bool(UNQUOTED_EXPANSION.search(self.raw))

    @property
    def globs(self) -> bool:
        return not self.quoted and bool(GLOB_PATTERN.search(self.text))


class Stage(NamedTuple):
    words: tuple[Token, ...]
    inputs: tuple[Token, ...]
    outputs: tuple[Token, ...]


class Invocation(NamedTuple):
    program: str
    family: Optional[str]
    target: Optional[str] = None
    inline: bool = False
    module: Optional[str] = None

    @property
    def runs_test_runner(self) -> bool:
        return self.module == TEST_RUNNER_MODULE

    @property
    def runs_script_file(self) -> bool:
        return self.family is not None and self.target is not None and not self.inline


def _variable_value(name: str) -> Optional[str]:
    if name == "HOME":
        return os.path.expanduser("~")
    return os.environ.get(name) or None


def expand_known_variables(text: str) -> str:
    for name in KNOWN_VARIABLES:
        value = _variable_value(name)
        if value is not None:
            pattern = re.compile(rf"\$(?:\{{{name}\}}|{name}(?![A-Za-z0-9_]))")
            text = pattern.sub(value.replace("\\", "\\\\"), text)
    return text


def shell_words(command: str) -> Optional[list[str]]:
    try:
        return shlex.split(command, comments=True)
    except ValueError:
        return None


def fallback_words(command: str) -> list[str]:
    tokens = (token.strip(QUOTE_CHARS) for token in SHELL_SPLIT.split(command))
    return [token for token in tokens if token]


def command_words(command: str) -> list[str]:
    words = shell_words(command)
    return fallback_words(command) if words is None else words


def _token(raw: str) -> Optional[Token]:
    if SHELL_OPERATOR.fullmatch(raw):
        return Token(raw, raw, operator=True)
    words = [] if raw.startswith("#") else shlex.split(raw)
    return Token(words[0], raw, operator=False) if len(words) == 1 else None


def shell_tokens(command: str) -> Optional[list[Token]]:
    if UNSAFE_TEXT.search(command):
        return None
    lexer = shlex.shlex(command, posix=False, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        tokens = [_token(raw) for raw in lexer]
    except ValueError:
        return None
    return None if None in tokens else tokens


def _redirection(tokens: list[Token], index: int) -> Optional[Token]:
    following = tokens[index + 1] if index + 1 < len(tokens) else None
    if tokens[index].text not in REDIRECTIONS or following is None or following.operator:
        return None
    return following


def _stage(tokens: list[Token]) -> Optional[Stage]:
    words: list[Token] = []
    inputs: list[Token] = []
    outputs: list[Token] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not token.operator:
            words.append(token)
            index += 1
            continue
        target = _redirection(tokens, index)
        if target is None:
            return None
        if words and DESCRIPTOR_NUMBER.fullmatch(words[-1].raw):
            words.pop()
        duplicate = token.text in DUPLICATIONS and DESCRIPTOR_TARGET.fullmatch(target.text)
        if not duplicate:
            (inputs if token.text == "<" else outputs).append(target)
        index += 2
    return Stage(tuple(words), tuple(inputs), tuple(outputs)) if words else None


def command_stages(tokens: list[Token]) -> Optional[list[Stage]]:
    groups: list[list[Token]] = [[]]
    for token in tokens:
        if token.operator and token.text == "|":
            groups.append([])
        else:
            groups[-1].append(token)
    stages = [_stage(group) for group in groups]
    return None if None in stages else stages


def segment_stages(segment: str) -> Optional[list[Stage]]:
    tokens = shell_tokens(segment)
    return None if tokens is None else command_stages(tokens)


def _skip_options(words: list[str], index: int, valued: frozenset) -> int:
    while index < len(words) and words[index].startswith("-") and words[index] != "-":
        if words[index] == "--":
            return index + 1
        index += 2 if words[index] in valued else 1
    return index


def _skip_wrappers(words: list[str]) -> int:
    index = 0
    while index < len(words):
        name = os.path.basename(words[index])
        if ASSIGNMENT.fullmatch(words[index]):
            index += 1
            continue
        valued = WRAPPER_VALUE_FLAGS.get(name)
        if valued is None:
            return index
        index = _skip_options(words, index + 1, valued)
        if name == "timeout":
            index += 1
    return index


def _family(name: str) -> Optional[str]:
    return "python" if PYTHON_NAME.fullmatch(name) else FAMILIES.get(name)


def _inline_flag(flag: str, family: str) -> bool:
    if flag.startswith("--"):
        return flag.split("=", 1)[0] in INLINE_LONG_FLAGS.get(family, frozenset())
    return any(letter in flag[1:] for letter in INLINE_LETTERS[family])


def _interpreted(name: str, family: str, args: list[str]) -> Invocation:
    index = 0
    while index < len(args) and args[index][:1] in "-+" and args[index] not in ("-", "--"):
        flag = args[index]
        if family == "python" and flag.startswith("-m"):
            module = flag[2:] or (args[index + 1] if index + 1 < len(args) else "")
            return Invocation(name, family, module=module)
        if _inline_flag(flag, family):
            return Invocation(name, family, inline=True)
        index += 2 if flag in INTERPRETER_VALUE_FLAGS[family] else 1
    if index < len(args) and args[index] == "--":
        index += 1
    target = args[index] if index < len(args) else None
    if family != "source" and target in STDIN_TARGETS:
        return Invocation(name, family, inline=True)
    return Invocation(name, family, target=target)


def invocation(words: list[str]) -> Optional[Invocation]:
    index = _skip_wrappers(words)
    if index >= len(words):
        return None
    program = words[index]
    name = os.path.basename(program)
    if name == "eval":
        return Invocation(name, None, inline=True)
    family = _family(name)
    if family is None:
        return Invocation(name, None, target=program)
    return _interpreted(name, family, words[index + 1 :])


def mentions_interpreter(words: list[str]) -> bool:
    names = (os.path.basename(word) for word in words)
    return any(name in ("eval", "xargs") or _family(name) not in (None, "source") for name in names)


def runs_inline_code(segment: str) -> bool:
    stages = segment_stages(segment)
    if stages is None:
        return mentions_interpreter(command_words(segment))
    calls = (invocation(stage_texts(stage)) for stage in stages)
    return any(call is not None and call.inline for call in calls)


def stage_texts(stage: Stage) -> list[str]:
    return [token.text for token in stage.words]


def stage_calls(segment: str) -> Optional[list[Optional[Invocation]]]:
    stages = segment_stages(segment)
    return None if stages is None else [invocation(stage_texts(stage)) for stage in stages]
