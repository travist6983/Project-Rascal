"""Seven clips into one file. The transcode step, and the scope line it crosses.

`CLAUDE.md` lists "thumbnail or transcode pipelines" as out of scope for the API lane and says
to stop if you find yourself designing one. **This is one, and it was authorised deliberately
by the owner on Aug 20, 2026** — recorded in `docs/decisions.md` rather than assumed, because
the out-of-scope list is a decision and not a formality. The scope line is amended to say so;
a list that quietly stops being true is the failure that file already records twice.

**Concat without re-encoding, when the inputs allow it.** Every clip comes from one model at
one resolution and one frame rate, so ffmpeg's concat demuxer can copy streams rather than
decode and re-encode them — seconds instead of minutes, and no generation loss on footage that
has already been through a codec once. The re-encode path exists for when that assumption
breaks, which it will the first time a treatment mixes a model's output with anything else.

**ffmpeg is a binary, not a library.** It is installed in the runtime image by the Dockerfile
and its absence is checked for at the top rather than discovered as a `FileNotFoundError`
three minutes into a job that has already spent real money on clips.

**Everything here is synchronous and belongs in a worker thread.** `subprocess.run` blocks, and
blocking the event loop for the length of a concat would stall every other request on the
machine. `renders.py` is what calls it, through `anyio.to_thread`.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

#: Long enough for a concat of a few dozen short clips and short enough that a wedged ffmpeg
#: does not hold a worker thread for the life of the process.
_TIMEOUT_SECONDS = 300


class StitchError(RuntimeError):
    """A concat that did not produce a file, carrying a sentence rather than ffmpeg's stderr."""


def available() -> bool:
    """Is there an ffmpeg on PATH at all? Checked before a job spends money on clips."""
    return shutil.which("ffmpeg") is not None


def concat(clips: list[bytes]) -> bytes:
    """Join clips in order and return one mp4.

    Tries a stream copy first because these are one model's output at one resolution, and falls
    back to a re-encode when the copy produces nothing usable — a mismatch in codec parameters
    is exactly what the demuxer refuses and exactly what a re-encode absorbs.
    """
    if not clips:
        raise StitchError("Nothing to stitch — no clips were produced.")
    if not available():
        raise StitchError(
            "ffmpeg is not installed, so the clips cannot be joined. They are each stored "
            "separately and can be assembled by hand."
        )
    if len(clips) == 1:
        # One shot is already the finished file. Running it through ffmpeg to prove a point
        # would be a re-encode for nothing.
        return clips[0]

    with tempfile.TemporaryDirectory(prefix="rascal-stitch-") as directory:
        workspace = Path(directory)
        paths = []
        for index, blob in enumerate(clips):
            path = workspace / f"{index:03d}.mp4"
            path.write_bytes(blob)
            paths.append(path)

        # The concat demuxer reads a list file. Paths are quoted per ffmpeg's own escaping
        # rules; they are generated here and contain no quotes, but the format requires it.
        listing = workspace / "clips.txt"
        listing.write_text("".join(f"file '{path.name}'\n" for path in paths))
        output = workspace / "out.mp4"

        copied = _run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                listing.name,
                "-c",
                "copy",
                # Timestamps restart at zero in every clip; without this the joined file
                # carries seven overlapping timelines and players show the first clip only.
                "-fflags",
                "+genpts",
                output.name,
            ],
            workspace,
        )
        if copied and output.exists() and output.stat().st_size:
            return output.read_bytes()

        # Re-encode. Slower and lossy, and still better than handing back nothing.
        output.unlink(missing_ok=True)
        encoded = _run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                listing.name,
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "20",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                # Vertical output stays vertical even if a clip came back the wrong way up.
                "-vf",
                "scale=720:1280:force_original_aspect_ratio=decrease,"
                "pad=720:1280:(ow-iw)/2:(oh-ih)/2,setsar=1",
                "-movflags",
                "+faststart",
                output.name,
            ],
            workspace,
        )
        if encoded and output.exists() and output.stat().st_size:
            return output.read_bytes()

    raise StitchError(
        "ffmpeg could not join the clips, by stream copy or by re-encoding. Each clip is "
        "stored separately and can be assembled by hand."
    )


def _run(command: list[str], cwd: Path) -> bool:
    """True when ffmpeg exited cleanly. Never raises on a non-zero exit — the caller decides.

    `cwd` is the temporary directory and every path in the command is a bare filename, which is
    what makes `-safe 0` tolerable: the concat list can only name files this function wrote.
    """
    try:
        # Fixed argv, no shell, and every filename is one this function wrote.
        result = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            timeout=_TIMEOUT_SECONDS,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return result.returncode == 0


__all__ = ["StitchError", "available", "concat"]
