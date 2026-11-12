import ast
from collections import defaultdict
from itertools import chain
from pathlib import Path
from typing import Iterator
import re
import sys


KEY = r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*"
PATH_READ = re.compile(r"(?<![\w.\]])\.([a-z][a-zA-Z0-9_]*(?:\.[a-z][a-zA-Z0-9_]*)*)")
JQ_READ = re.compile(r"(?<![\w\"'])\bjq\b[^'\n]*'([^']*)'([^\n]*)")
SOURCE = re.compile(r"config\.json|\$\{?\w*config\w*|\$\{?MERGED_SETTINGS", re.I)


def documented_keys(root: Path) -> dict[str, str]:
    rows = {}
    for line in (root / "commands/config.md").read_text().splitlines():
        cells = [cell.strip().strip('`') for cell in line.split('|')]
        if len(cells) > 4 and re.fullmatch(KEY, cells[1]) and cells[2] in {
            "string", "boolean", "number", "integer", "object", "array", "boolean/number"
        }:
            rows[cells[1]] = line
    return rows


def paths(expression: str) -> set[str]:
    expression = re.sub(r'\bdef\s+[^;]+;', '', expression)
    expression = re.sub(r'"(?:\\.|[^"\\])*"', '""', expression)
    segments = re.split(r'(?<!\|)\|(?!\|)', expression)
    candidates = ({match[1] for match in PATH_READ.finditer(segment)
                   if not re.match(r'\s*(?:=(?!=)|\|=)', segment[match.end():])}
                  for segment in segments)
    return next((found for found in candidates if found), set())


def add_reads(reads: dict, found: set[str], location: str) -> None:
    for key in found:
        reads[key].add(location)
        if key.startswith(("tmux_execution.", "workflow_execution.")):
            reads[key.split('.')[0]].add(location)
        if key.startswith("tmux_execution.restrictions."):
            reads['tmux_execution.restrictions'].add(location)


def shell_reads(path: Path, text: str, reads: dict) -> None:
    original = text
    text = text.replace('\\\n', '  ')
    variables = re.findall(r'(\w+)=[^\n]*config\.json', text)
    for match in JQ_READ.finditer(text):
        line = original.count('\n', 0, match.start()) + 1
        context = match[2].split(')', 1)[0]
        if 'GLOBAL_CONFIG_FILE' in context:
            continue
        found = paths(match[1])
        prefix = 'tmux_execution.' if 'CONFIG_TMUX' in context else ''
        prefix = 'workflow_execution.' if 'CONFIG_WORKFLOW' in context else prefix
        found = {prefix + key for key in found}
        if SOURCE.search(context) or any(re.search(r'\$\{?' + name + r'\b', context) for name in variables):
            add_reads(reads, found, f"{path}:{line}")
        if 'SNAPSHOT_PATH' in context:
            add_reads(reads, {key for key in found if key.startswith(('tmux_execution.', 'workflow_execution.'))}, f"{path}:{line}")
    filter_reads(path, text, reads)
    prose_reads(path, original, reads)
    for match in re.finditer(r'\$config\.(' + KEY + ')', text):
        add_reads(reads, {match[1]}, str(path))
    for match in re.finditer(r'lookup_round_cap_key\s+"\$config_path"\s+"(' + KEY + ')"', text):
        add_reads(reads, {match[1]}, str(path))
    for match in re.finditer(r'meridian-config\.sh["\s]+get\s+\S+\s+(' + KEY + ')', text):
        add_reads(reads, {match[1]}, str(path))


def filter_reads(path: Path, text: str, reads: dict) -> None:
    for match in re.finditer(r'\bjq\b[^\n]*-f[^\n]*', text):
        if not SOURCE.search(match[0]):
            continue
        names = re.findall(r'/([a-z0-9-]+\.jq)', match[0])
        candidates = chain.from_iterable((path.parent / name, path.parent / 'lib' / name) for name in names)
        for candidate in (item for item in candidates if item.is_file()):
            add_reads(reads, paths(candidate.read_text()), str(candidate))


def prose_reads(path: Path, text: str, reads: dict) -> None:
    if path.suffix not in {'.md', '.tpl'}:
        return
    for number, line in enumerate(text.splitlines(), 1):
        if not re.search(r'config|settings', line, re.I):
            continue
        for match in re.finditer(r'(?<![-\w])read\s+(?:config\.json\s+for\s+)?(`' + KEY + r'`.*?)(?:\.\s|$)', line, re.I):
            add_reads(reads, set(re.findall(r'`(' + KEY + ')`', match[1])), f'{path}:{number}')


def source_files(root: Path) -> Iterator[Path]:
    candidates = chain.from_iterable((root / directory).rglob('*') for directory in ('scripts', 'hooks', 'commands', 'references', 'templates'))
    for path in sorted(candidates):
        if not path.is_file() or path.suffix not in {'.sh', '.jq', '.py', '.md', '.tpl', ''}:
            continue
        if any(part in {'tests', '__pycache__', 'import-adapters'} for part in path.relative_to(root).parts):
            continue
        if path.name.startswith(('test_', 'check_config_keys', 'check-config-keys')):
            continue
        if path.name in {'meridian-config-validate.jq', 'meridian-config-migrate.jq'}:
            continue
        yield path


def python_key(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return '' if re.search('config|settings', node.id, re.I) else None
    if isinstance(node, ast.Subscript):
        parent, key = node.value, node.slice
    elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'get' and node.args:
        parent, key = node.func.value, node.args[0]
    else:
        return None
    prefix = python_key(parent)
    if prefix is not None and isinstance(key, ast.Constant) and isinstance(key.value, str):
        return '.'.join(part for part in (prefix, key.value) if part)
    return None


def python_reads(path: Path, text: str, reads: dict) -> None:
    if path.suffix != '.py' or 'config.json' not in text:
        return
    for node in ast.walk(ast.parse(text)):
        key = python_key(node)
        if key:
            add_reads(reads, {key}, f'{path}:{node.lineno}')


def code_reads(root: Path, documented: dict) -> dict[str, set[str]]:
    reads = defaultdict(set)
    for path in source_files(root):
        text = path.read_text()
        shell_reads(path, text, reads)
        python_reads(path, text, reads)
    validator = (root / 'scripts/lib/meridian-config-validate.jq').read_text()
    for key, row in documented.items():
        if '[persistence-only]' in row and key in PATH_READ.findall(validator):
            reads[key].add('scripts/lib/meridian-config-validate.jq')
    return reads


def main() -> int:
    root = Path(sys.argv[1])
    documented = documented_keys(root)
    reads = code_reads(root, documented)
    print('Documented keys')
    for key in sorted(documented):
        print('  ' + key)
    print('Code-read keys')
    for key in sorted(reads):
        print('  ' + key)
    missing = sorted(set(documented) - set(reads))
    extra = sorted(set(reads) - set(documented))
    for key in missing:
        print(f'Documented without a reader  {key}')
    for key in extra:
        print(f'Read without documentation  {key}  {", ".join(sorted(reads[key]))}')
    print(f'Differences  {len(missing) + len(extra)}')
    return int(bool(missing or extra))


if __name__ == '__main__':
    raise SystemExit(main())
