from __future__ import annotations

import fnmatch
import glob
import os
from dataclasses import dataclass, replace
from itertools import islice
from pathlib import Path
from typing import Iterable, Iterator, Optional

FILE_CAP = 2048
GLOB_CAP = 1024
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


def _within(real: str, root: str) -> bool:
    return real == root or real.startswith(root.rstrip(os.sep) + os.sep)


def _iter_files(root: Path) -> Iterator[str]:
    for dirpath, _, names in os.walk(root):
        yield from (os.path.join(dirpath, name) for name in names)


def _segment_matches(actual: str, pattern: str) -> bool:
    hidden_ok = pattern.startswith(".") or not actual.startswith(".")
    return hidden_ok and fnmatch.fnmatchcase(actual.casefold(), pattern.casefold())


def _match(actual: tuple, pattern: tuple, exact: bool) -> bool:
    if not actual:
        return not exact or all(part == "**" for part in pattern)
    if not pattern:
        return False
    head, rest = pattern[0], pattern[1:]
    if head == "**":
        return _match(actual, rest, exact) or _match(actual[1:], pattern, exact)
    return _segment_matches(actual[0], head) and _match(actual[1:], rest, exact)


def _glob_reaches(pattern: str, target: Path, exact: bool) -> bool:
    parts = Path(os.path.normpath(pattern)).parts
    return _match(target.parts, parts, exact)


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
        if _within(real.casefold(), self.runtime_real):
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
            _within(real.casefold(), os.path.realpath(module).casefold())
            for module in self.modules if module.is_dir()
        )

    def hits(self, path: str) -> bool:
        real = os.path.realpath(path)
        return self._runtime_hit(real) or self._module_hit(real)

    def glob_hits(self, pattern: str) -> bool:
        if self.runtime is not None and _glob_reaches(pattern, self.runtime, False):
            return True
        return any(_glob_reaches(pattern, module, True) for module in self.modules)
