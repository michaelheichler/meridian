from __future__ import annotations

import fnmatch
import glob
import os
from dataclasses import dataclass, replace
from itertools import islice, takewhile
from pathlib import Path
from typing import Iterable, Iterator, Optional

FILE_CAP = 2048
GLOB_CAP = 1024
GLOB_CHARS = "*?["
FileId = tuple[int, int]


class TooManyMatches(Exception):
    pass


def _stat_id(path: str) -> Optional[FileId]:
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (info.st_dev, info.st_ino)


def _link_count(path: str) -> int:
    try:
        return os.stat(path).st_nlink
    except OSError:
        return 0


def _chain(real: str) -> list[str]:
    chain = [real]
    while os.path.dirname(chain[-1]) != chain[-1]:
        chain.append(os.path.dirname(chain[-1]))
    return chain


def within(real: str, root: str) -> bool:
    return real == root or real.startswith(root.rstrip(os.sep) + os.sep)


def _iter_files(root: Path) -> Iterator[str]:
    for dirpath, _, names in os.walk(root):
        yield from (os.path.join(dirpath, name) for name in names)


def _segment_matches(actual: str, pattern: str) -> bool:
    hidden_ok = pattern.startswith(".") or not actual.startswith(".")
    return hidden_ok and fnmatch.fnmatchcase(actual.casefold(), pattern.casefold())


def _match(actual: tuple, pattern: tuple) -> bool:
    if not actual:
        return all(part == "**" for part in pattern)
    if not pattern:
        return False
    head, rest = pattern[0], pattern[1:]
    if head == "**":
        return _match(actual, rest) or _match(actual[1:], pattern)
    return _segment_matches(actual[0], head) and _match(actual[1:], rest)


def _glob_matches(pattern: str, target: Path) -> bool:
    return _match(target.parts, Path(os.path.normpath(pattern)).parts)


def _glob_enters(pattern: str, directory: Path) -> bool:
    folders = Path(os.path.normpath(pattern)).parent.parts
    if not any(char in part for part in folders for char in GLOB_CHARS):
        return False
    return any(_match(directory.parts, folders[:depth]) for depth in range(1, len(folders) + 1))


def _literal_prefix(pattern: str) -> str:
    parts = Path(os.path.normpath(pattern)).parts
    literal = takewhile(lambda part: not any(char in part for char in GLOB_CHARS), parts)
    return str(Path(*literal))


def _iter_glob(pattern: str, recursive: bool) -> Iterator[str]:
    try:
        return glob.iglob(pattern, recursive=recursive, include_hidden=True)
    except TypeError:
        return glob.iglob(pattern, recursive=recursive)


def expand_glob(pattern: str) -> list[str]:
    matches = list(islice(_iter_glob(pattern, "**" in pattern), GLOB_CAP + 1))
    if len(matches) > GLOB_CAP:
        raise TooManyMatches(pattern)
    return matches


def iter_matches(pattern: str) -> Iterator[str]:
    return _iter_glob(pattern, "**" in pattern)


@dataclass(frozen=True)
class ProtectedIdentity:
    runtime: Optional[Path]
    runtime_real: Optional[str]
    runtime_id: Optional[FileId]
    runtime_file_ids: frozenset
    overflow: bool
    modules: frozenset
    module_reals: frozenset
    module_ids: frozenset

    @staticmethod
    def build(planning_dir: Optional[Path], modules: Iterable[Path]) -> ProtectedIdentity:
        runtime = None if planning_dir is None else planning_dir / ".runtime"
        paths = list(islice(_iter_files(runtime), FILE_CAP + 1)) if runtime else []
        file_ids = frozenset(item for item in map(_stat_id, paths[:FILE_CAP]) if item)
        module_paths = frozenset(modules)
        module_ids = frozenset(item for item in map(_stat_id, map(str, module_paths)) if item)
        real = None if runtime is None else os.path.realpath(runtime).casefold()
        reals = frozenset(os.path.realpath(path).casefold() for path in module_paths)
        runtime_id = None if runtime is None else _stat_id(str(runtime))
        return ProtectedIdentity(
            runtime, real, runtime_id, file_ids, len(paths) > FILE_CAP, module_paths, reals, module_ids
        )

    def runtime_only(self) -> ProtectedIdentity:
        return replace(self, modules=frozenset(), module_reals=frozenset(), module_ids=frozenset())

    def _runtime_hit(self, real: str) -> bool:
        if self.runtime_real is None:
            return False
        if within(real.casefold(), self.runtime_real):
            return True
        ids = [_stat_id(item) for item in _chain(real)]
        known = self.runtime_id is not None and self.runtime_id in ids
        return known or self._file_hit(real, ids[0])

    def _file_hit(self, real: str, leaf: Optional[FileId]) -> bool:
        if leaf is not None and leaf in self.runtime_file_ids:
            return True
        return self.overflow and leaf is not None and _link_count(real) > 1

    def _module_hit(self, real: str) -> bool:
        leaf = _stat_id(real)
        if real.casefold() in self.module_reals or (leaf is not None and leaf in self.module_ids):
            return True
        return any(
            within(real.casefold(), os.path.realpath(module).casefold())
            for module in self.modules if module.is_dir()
        )

    def hits(self, path: str) -> bool:
        real = os.path.realpath(path)
        return self._runtime_hit(real) or self._module_hit(real)

    def glob_hits(self, pattern: str) -> bool:
        if self._runtime_hit(os.path.realpath(_literal_prefix(pattern))):
            return True
        if any(_glob_matches(pattern, module) for module in self.modules):
            return True
        return any(_glob_enters(pattern, module) for module in self.modules if module.is_dir())

    def holds_module_below(self, path: str) -> bool:
        real = os.path.realpath(path).casefold()
        return any(within(reality, real) for reality in self.module_reals)
