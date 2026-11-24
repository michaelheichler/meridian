from __future__ import annotations

import glob
import os
from enum import Enum
from pathlib import Path
from typing import NamedTuple, Optional

if __package__:
    from .path_identity import expand_glob
    from .read_only_command import command_segments, is_read_stage
    from .shell_invocation import (
        Stage, Token, command_words, invocation, runs_helper, segment_stages,
    )
else:
    from path_identity import expand_glob
    from read_only_command import command_segments, is_read_stage
    from shell_invocation import (
        Stage, Token, command_words, invocation, runs_helper, segment_stages,
    )


class SegmentKind(Enum):
    READ = "read"
    RUN = "run"


class SegmentView(NamedTuple):
    kind: Optional[SegmentKind]
    loose: list[str]
    strict: list[str]
    text: str


class CommandView(NamedTuple):
    command: str
    loose: list[str]
    strict: list[str]
    strict_text: str
    reads_only: bool


def _plain_source_glob(word: str, cwd: Path) -> bool:
    matches = expand_glob(os.path.join(str(cwd), word))
    return bool(matches) and all(
        Path(match).is_file() and not Path(match).is_symlink() for match in matches
    )


def _literal(token: Token) -> str:
    return glob.escape(token.text) if token.quoted else token.text


def _static(token: Token, cwd: Path) -> bool:
    return not token.expands and (not token.globs or _plain_source_glob(token.text, cwd))


def _stage_kind(stage: Stage, cwd: Path) -> Optional[SegmentKind]:
    if not all(_static(token, cwd) for token in (*stage.words, *stage.inputs)):
        return None
    words = [token.text for token in stage.words]
    if is_read_stage(words, str(cwd)):
        return SegmentKind.READ
    call = invocation(words)
    return SegmentKind.RUN if call is not None and runs_helper(call) else None


def _segment_view(segment: str, cwd: Optional[Path]) -> SegmentView:
    stages = segment_stages(segment)
    if stages is None or cwd is None:
        return SegmentView(None, [], command_words(segment), segment)
    kinds = [_stage_kind(stage, cwd) for stage in stages]
    if None in kinds:
        return SegmentView(None, [], command_words(segment), segment)
    loose = [_literal(token) for stage in stages for token in (*stage.words, *stage.inputs)]
    outputs = [token for stage in stages for token in stage.outputs]
    kind = SegmentKind.RUN if SegmentKind.RUN in kinds else SegmentKind.READ
    targets = [_literal(token) for token in outputs]
    return SegmentView(kind, loose, targets, " ".join(token.raw for token in outputs))


def command_view(command: str, cwd: Optional[Path]) -> CommandView:
    segments = [_segment_view(segment, cwd) for segment in command_segments(command)]
    strict = [word for segment in segments for word in segment.strict]
    reads_only = not strict and all(segment.kind is SegmentKind.READ for segment in segments)
    return CommandView(
        command,
        [word for segment in segments for word in segment.loose],
        strict,
        "\n".join(segment.text for segment in segments),
        reads_only,
    )
