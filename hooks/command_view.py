from __future__ import annotations

import glob
import os
from enum import Enum
from pathlib import Path, PurePath
from typing import NamedTuple, Optional

if __package__:
    from .path_identity import GLOB_CHARS, expand_glob
    from .read_only_command import command_segments, is_read_stage
    from .shell_invocation import (
        EXPANSION_CHARS, SHELL_SPLIT, UNRESOLVED_CHARS, Invocation, Stage, Token, command_words,
        expand_known_variables, invocation, segment_stages, stage_texts,
    )
else:
    from path_identity import GLOB_CHARS, expand_glob
    from read_only_command import command_segments, is_read_stage
    from shell_invocation import (
        EXPANSION_CHARS, SHELL_SPLIT, UNRESOLVED_CHARS, Invocation, Stage, Token, command_words,
        expand_known_variables, invocation, segment_stages, stage_texts,
    )

HELPER_SUFFIXES = frozenset({".sh", ".py"})
HELPER_PROGRAMS = frozenset({"meridian-model"})
LOCATION_COMMANDS = frozenset({"cd", "pushd"})


class StageKind(Enum):
    READ = "read"
    HELPER = "helper"
    TEST_RUNNER = "test-runner"
    SCRIPT = "script"


class ViewContext(NamedTuple):
    cwd: Path
    helper_directories: frozenset[str]


class SegmentView(NamedTuple):
    kinds: tuple[Optional[StageKind], ...]
    runtime_words: tuple[str, ...]
    source_words: tuple[str, ...]
    source_text: str

    @property
    def classified(self) -> bool:
        return bool(self.kinds) and None not in self.kinds

    @property
    def reads_only(self) -> bool:
        return self.classified and not self.source_words and set(self.kinds) == {StageKind.READ}


class CommandView(NamedTuple):
    command: str
    segments: tuple[SegmentView, ...]
    unclassified_texts: tuple[str, ...]

    @property
    def runtime_words(self) -> tuple[str, ...]:
        return tuple(word for segment in self.segments for word in segment.runtime_words)

    @property
    def source_words(self) -> tuple[str, ...]:
        return tuple(word for segment in self.segments for word in segment.source_words)

    @property
    def every_word(self) -> tuple[str, ...]:
        return self.runtime_words + self.source_words

    @property
    def source_text(self) -> str:
        return "\n".join(segment.source_text for segment in self.segments)

    @property
    def reads_only(self) -> bool:
        return all(segment.reads_only for segment in self.segments)


def _plain_source_glob(word: str, cwd: Path) -> bool:
    matches = expand_glob(os.path.join(str(cwd), word))
    return bool(matches) and all(
        Path(match).is_file() and not Path(match).is_symlink() for match in matches
    )


def _literal(token: Token) -> str:
    return glob.escape(token.text) if token.quoted else token.text


def _static(token: Token, cwd: Path) -> bool:
    return not token.expands and (not token.globs or _plain_source_glob(token.text, cwd))


def _resolved_helper(target: str, context: ViewContext) -> bool:
    if any(char in target for char in (*UNRESOLVED_CHARS, *GLOB_CHARS)):
        return False
    path = PurePath(os.path.realpath(os.path.join(str(context.cwd), os.path.expanduser(target))))
    helper = path.suffix in HELPER_SUFFIXES or path.name in HELPER_PROGRAMS
    return helper and str(path.parent).casefold() in context.helper_directories


def _call_kind(call: Invocation, context: ViewContext) -> Optional[StageKind]:
    if call.target is not None and not call.inline and _resolved_helper(call.target, context):
        return StageKind.HELPER
    return StageKind.SCRIPT if call.runs_script_file else None


def _stage_kind(stage: Stage, context: ViewContext) -> Optional[StageKind]:
    static = all(_static(token, context.cwd) for token in (*stage.words, *stage.inputs))
    texts = [token.text for token in stage.words]
    if static and is_read_stage(texts, str(context.cwd)):
        return StageKind.READ
    call = invocation([expand_known_variables(text) for text in texts])
    if call is None:
        return None
    if call.runs_test_runner:
        return StageKind.TEST_RUNNER if static else None
    return _call_kind(call, context)


def _helper_words(stage: Stage) -> tuple[list[str], list[str]]:
    call = invocation([expand_known_variables(token.text) for token in stage.words])
    target = None if call is None else call.target
    words = [_literal(token) for token in stage.words]
    expanded = [expand_known_variables(token.text) for token in stage.words]
    index = expanded.index(target) if target in expanded else len(words)
    return words[index : index + 1], words[:index] + words[index + 1 :]


def _stage_words(stage: Stage, kind: StageKind) -> tuple[list[str], list[str]]:
    inputs = [_literal(token) for token in stage.inputs]
    outputs = [_literal(token) for token in stage.outputs]
    if kind is StageKind.HELPER:
        target, arguments = _helper_words(stage)
        return target + inputs, arguments + outputs
    words = [_literal(token) for token in stage.words]
    if kind is StageKind.SCRIPT:
        return inputs, words + outputs
    return words + inputs, outputs


def _unclassified(segment: str) -> SegmentView:
    return SegmentView((None,), (), tuple(command_words(segment)), segment)


def _segment_view(segment: str, context: Optional[ViewContext]) -> SegmentView:
    stages = segment_stages(segment)
    if stages is None or context is None:
        return _unclassified(segment)
    kinds = [_stage_kind(stage, context) for stage in stages]
    if None in kinds:
        return _unclassified(segment)
    runtime_words: list[str] = []
    source_words: list[str] = []
    for stage, kind in zip(stages, kinds, strict=True):
        relaxed, checked = _stage_words(stage, kind)
        runtime_words += relaxed
        source_words += checked
    outputs = " ".join(token.raw for stage in stages for token in stage.outputs)
    return SegmentView(tuple(kinds), tuple(runtime_words), tuple(source_words), outputs)


def command_view(command: str, context: Optional[ViewContext]) -> CommandView:
    pieces = command_segments(command)
    segments = tuple(_segment_view(piece, context) for piece in pieces)
    unclassified = tuple(
        piece for piece, segment in zip(pieces, segments, strict=True) if not segment.classified
    )
    return CommandView(command, segments, unclassified)


def has_expansion(word: str) -> bool:
    return any(char in word for char in EXPANSION_CHARS) or word.startswith("~")


def _moves_location(words: list[str], index: int) -> bool:
    return words[index] == "-C" or (index == 0 and words[0] in LOCATION_COMMANDS)


def _location_targets(segment: str) -> list[str]:
    stages = segment_stages(segment)
    if stages is None:
        raws = [raw.strip("'\"") for raw in SHELL_SPLIT.split(segment) if raw]
        movers = (*LOCATION_COMMANDS, "-C")
        return [raws[index + 1] for index in range(len(raws) - 1) if raws[index] in movers]
    targets: list[str] = []
    for stage in stages:
        words = stage_texts(stage)
        moves = (index for index in range(len(words) - 1) if _moves_location(words, index))
        targets.extend(words[index + 1] for index in moves)
    return targets


def command_locations(command: str, cwd: Path) -> tuple[list[Path], bool]:
    locations = [cwd]
    unresolved = False
    for segment in command_segments(command):
        for raw in _location_targets(segment):
            target = expand_known_variables(raw)
            if has_expansion(target):
                unresolved = True
                continue
            locations.append(Path(os.path.join(str(locations[-1]), target)).resolve())
    return locations, unresolved
