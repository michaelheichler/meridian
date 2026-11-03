import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
from types import FrameType
from typing import Callable


def publisher(root: Path, planning: Path, published: list) -> Callable:
    existing = set(planning.iterdir())
    payload = json.dumps({"session_id": "s1", "workspace": {"project_dir": str(Path.cwd())},
                          "context_window": {"used_percentage": 72.5, "context_window_size": 1000000}})

    def publish_after_close(frame: FrameType, event: str, _argument: object) -> None:
        if event != "return" or frame.f_code.co_name != "__exit__":
            return
        if frame.f_globals.get("__name__") != "tempfile":
            return
        sys.setprofile(None)
        staged = list(set(planning.iterdir()) - existing)
        assert len(staged) == 1, "estimate must reach the closed staging file before publication"
        assert staged[0].read_text().startswith("s1|"), "estimate staging file was empty"
        subprocess.run(["bash", str(root / "scripts/lbwc-statusline.sh")], input=payload,
                       text=True, stdout=subprocess.DEVNULL, check=True, timeout=10,
                       env=dict(os.environ, LBWC_PLANNING_DIR=str(planning)))
        published.append(True)

    return publish_after_close


def main() -> None:
    root = Path(sys.argv[1])
    planning = Path.cwd() / ".lbwc-planning"
    published = []
    sys.setprofile(publisher(root, planning, published))
    try:
        sys.argv = [str(root / "hooks/context_usage.py")]
        runpy.run_path(sys.argv[0], run_name="__main__")
    finally:
        sys.setprofile(None)
    assert published, "the native publisher never ran after staging closed"
    assert (planning / ".context-usage").read_text().strip() == "s1|72.5|1000000|statusline", (
        "estimate overwrote the newer native measurement")
    assert set(planning.iterdir()) == {planning / ".context-usage"}, "discarded estimate staging file leaked"


if __name__ == "__main__":
    main()
