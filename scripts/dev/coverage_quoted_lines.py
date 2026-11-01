import re

# kcov marks lines inside a multi-line quoted string as code, so they are dropped.
HEREDOC = re.compile(r"<<(-?)\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
WORD_BREAK = " \t;&|()"
NESTED = ("c", "p")


class QuoteScanner:
    def __init__(self) -> None:
        self.stack: list[str] = ["n"]
        self.heredocs: list[tuple[str, bool]] = []
        self.handlers = {"s": self.scan_single, "d": self.scan_double}

    def top(self) -> str:
        return self.stack[-1]

    def in_string(self) -> bool:
        return self.top() in ("s", "d")

    def scan_single(self, line: str, index: int) -> int:
        if line[index] == "'":
            self.stack.pop()
        return 1

    def scan_double(self, line: str, index: int) -> int:
        if line[index] == "\\":
            return 2
        if line[index] == '"':
            self.stack.pop()
            return 1
        if line.startswith("$(", index):
            self.stack.append("c")
            return 2
        return 1

    def scan_code(self, line: str, index: int) -> int:
        char = line[index]
        if char == "\\":
            return 2
        if char == "#" and (index == 0 or line[index - 1] in WORD_BREAK):
            return len(line) - index
        if char in "'\"":
            self.stack.append("s" if char == "'" else "d")
            return 1
        if line.startswith("$(", index):
            self.stack.append("c")
            return 2
        self.scan_structure(line, index)
        return 1

    def scan_structure(self, line: str, index: int) -> None:
        char = line[index]
        nested = self.top() in NESTED
        if char == "(" and nested:
            self.stack.append("p")
            return
        if char == ")" and nested:
            self.stack.pop()
            return
        if line.startswith("<<", index) and not line.startswith("<<<", index):
            self.queue_heredoc(line[index:])

    def queue_heredoc(self, rest: str) -> None:
        match = HEREDOC.match(rest)
        if match:
            self.heredocs.append((match.group(2), match.group(1) == "-"))

    def scan_line(self, line: str) -> None:
        index = 0
        while index < len(line):
            index += self.handlers.get(self.top(), self.scan_code)(line, index)


class LineFilter:
    def __init__(self) -> None:
        self.scanner = QuoteScanner()
        self.pending: list[tuple[str, bool]] = []

    def heredoc_body(self, line: str) -> bool:
        if not self.pending:
            return False
        delimiter, strip_tabs = self.pending[0]
        if (line.lstrip("\t") if strip_tabs else line) == delimiter:
            self.pending.pop(0)
        return True

    def drops(self, line: str) -> bool:
        if self.heredoc_body(line):
            return True
        inside = self.scanner.in_string()
        self.scanner.scan_line(line)
        self.pending, self.scanner.heredocs = self.scanner.heredocs, []
        return inside


def quoted_lines(lines: list[str]) -> set[int]:
    line_filter = LineFilter()
    return {number for number, line in enumerate(lines, start=1) if line_filter.drops(line)}
