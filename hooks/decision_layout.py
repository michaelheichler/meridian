from __future__ import annotations

from pathlib import Path
from typing import cast

if __package__:
    from .decision_common import (
        INVALID_RECORD,
        INVALID_STATE,
        SESSION_PATTERN,
        is_physical_directory,
        is_present,
        require,
    )
else:
    from decision_common import (
        INVALID_RECORD,
        INVALID_STATE,
        SESSION_PATTERN,
        is_physical_directory,
        is_present,
        require,
    )


def _absent_or_link(path: Path) -> bool:
    return not path.exists() or path.is_symlink()


class DecisionLayout:
    def __init__(self, planning_dir: Path) -> None:
        planning_dir = planning_dir.resolve()
        require(is_physical_directory(planning_dir), INVALID_STATE)
        self.planning_dir = planning_dir

    @staticmethod
    def ensure_directory(path: Path) -> Path:
        if is_present(path):
            require(is_physical_directory(path), INVALID_STATE)
        else:
            path.mkdir(mode=0o700)
        return path

    def decisions_directory(self, create: object) -> Path | None:
        runtime = self.planning_dir / ".runtime"
        decisions = runtime / "decisions"
        if not create and not is_present(runtime):
            return None
        self.ensure_directory(runtime)
        if not create and not is_present(decisions):
            return None
        return self.ensure_directory(decisions)

    def record_path(self, session_id: str, create: object) -> Path | None:
        require(bool(SESSION_PATTERN.fullmatch(session_id)), INVALID_RECORD)
        decisions = self.decisions_directory(create)
        return None if decisions is None else decisions / f"{session_id}.json"

    def authority_path(self, session_id: str, transition_id: str) -> Path | None:
        decisions = self.decisions_directory(False)
        if decisions is None:
            return None
        authority = decisions / ".hook-transitions"
        session = authority / session_id
        if _absent_or_link(authority) or _absent_or_link(session):
            return None
        require(is_physical_directory(authority), INVALID_RECORD)
        require(is_physical_directory(session), INVALID_RECORD)
        return session / f"{transition_id}.json"

    def create_authority_path(self, session_id: str, transition_id: str) -> Path:
        decisions = cast(Path, self.decisions_directory(True))
        authority = self.ensure_directory(decisions / ".hook-transitions")
        session = self.ensure_directory(authority / session_id)
        return session / f"{transition_id}.json"
