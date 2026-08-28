"""One WebM in, one H.264 MP4 out. The transcode step, and the scope line it crosses.

**This replaces `stitch.py`, which joined clips.** There are no clips any more: the browser
records one continuous capture of the card renderer, so there is nothing to concatenate and the
concat demuxer, its stream-copy fast path and its duration-tolerance check all went with the
vendor that made them necessary. What is left is the one thing that was always load-bearing —
turning a browser's recording into a file a platform will accept.

`CLAUDE.md` lists "thumbnail or transcode pipelines" as out of scope for the API lane and says
to stop if you find yourself designing one. That line is struck **narrowly**, by the owner's
call of Aug 20, 2026, and phase 120 narrows it further rather than widening it: this handles
marketing output under `social/` that **this repository's own browser recorded seconds earlier**.
Nothing here reads a family's bytes, nothing touches the `children/` prefix, and the archive's
own byte path is untouched.

**Why a re-encode and never a stream copy.** Two reasons, and the second is the one that bites:

1. Nothing publishes VP9-in-WebM. Instagram, and every other surface a Pocket Chronicle
   post reaches, want H.264 in MP4. The codec has to change, so bytes have to move.
2. **`MediaRecorder` writes an unknown duration into the WebM header.** The spec permits it and
   Chrome does it: the Segment's duration element is absent or a placeholder, so `ffprobe` on
   the recording reports `N/A` and anything that trusts it gets nothing. The re-encode
   recomputes timestamps from the frames themselves, which is why the output's duration is
   worth asserting on and the input's is not. Do not add a fast path that copies the stream —
   it would carry the unknown duration straight through into the MP4.

**`-pix_fmt yuv420p` is load-bearing.** libx264 will happily pick `yuv444p` from a
high-quality VP9 source, and a 4:4:4 H.264 file is rejected by Instagram and misrendered by
QuickTime. It is one flag between "works" and "the file plays black on the owner's Mac".

**`-an` because there is no audio.** A canvas capture has no audio track, and asking ffmpeg to
encode one produces a silent AAC stream that is bytes for nothing. This is the single line that
changes the day a TTS pass is mixed in.

**ffmpeg is a binary, not a library.** It is installed in the runtime image by the Dockerfile
and its absence is checked for at the top rather than discovered as a `FileNotFoundError`.
Verified in the image this deploys, not on a laptop: `python:3.12-slim-bookworm` plus Debian's
`ffmpeg` is ffmpeg 5.1.9 carrying `libx264` and both `vp8` and `vp9` decoders.

**Everything here is synchronous and belongs in a worker thread.** `subprocess.run` blocks, and
blocking the event loop for the length of an encode would stall every other request on the
machine. `renders.py` is what calls it, through `anyio.to_thread`.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

#: EBML, which is WebM's container. Four bytes, checked before anything else touches the body,
#: for the same reason the card upload checks for JPEG: a wrong format otherwise surfaces as an
#: ffmpeg error that names neither the format nor the file, and sends the next person to read
#: the wrong code.
EBML_MAGIC = b"\x1a\x45\xdf\xa3"

#: A minute of 1080x1920 VP9 is a few megabytes; sixty is the outer bound of what this route
#: will accept and it is generous by a wide margin. It exists so a mis-aimed upload is refused
#: on its `Content-Length` rather than buffered into the machine's memory first.
MAX_RECORDING_BYTES = 64 * 1024 * 1024

#: Long enough for a minute of 1080x1920 at `veryfast`, and short enough that a wedged ffmpeg
#: does not hold a worker thread for the life of the process. Measured: a 12-second 1080x1920
#: recording encodes in about two seconds on the deployed machine class.
TIMEOUT_SECONDS = 180

#: What comes out. Frozen here rather than assembled at the call site so the tests can assert
#: against the argv the route actually runs.
_ENCODE = (
    "-c:v",
    "libx264",
    "-preset",
    "veryfast",
    "-crf",
    "20",
    "-profile:v",
    "high",
    # See the module docstring. Without this libx264 may choose 4:4:4 from a high-quality VP9
    # source and the result is rejected or misrendered rather than merely large.
    "-pix_fmt",
    "yuv420p",
    # Constant frame rate at the rate the canvas was captured at. `MediaRecorder` writes a
    # variable frame rate when the tab hiccups, and a VFR MP4 is what makes a platform's own
    # re-encode drift out of sync with a caption track.
    "-r",
    "30",
    # No audio track exists. See the module docstring.
    "-an",
    "-movflags",
    "+faststart",
)


class TranscodeError(RuntimeError):
    """A transcode that produced no file, carrying a sentence rather than ffmpeg's whole stderr."""


def available() -> bool:
    """Is there an ffmpeg on PATH at all? Checked before the browser is asked to record."""
    return shutil.which("ffmpeg") is not None


def to_mp4(recording: bytes) -> bytes:
    """Re-encode a browser recording to H.264 MP4, or raise a sentence saying why not.

    Never a stream copy — see the module docstring. The input is trusted only as far as its
    magic number; everything else about it is whatever Chrome felt like writing.
    """
    if not recording:
        raise TranscodeError("There was nothing to transcode — the recording was empty.")
    if not recording.startswith(EBML_MAGIC):
        raise TranscodeError(
            "That is not a WebM. The recorder sends an EBML container "
            f"(bytes {EBML_MAGIC.hex(' ')}) and this body starts "
            # Non-empty by the check above, so there is always at least one byte to name.
            f"{recording[:4].hex(' ')}."
        )
    if not available():
        raise TranscodeError(
            "ffmpeg is not installed on this machine, so the recording cannot be converted "
            "to the H.264 MP4 a platform will accept. Nothing was stored."
        )

    with tempfile.TemporaryDirectory(prefix="rascal-transcode-") as directory:
        workspace = Path(directory)
        source = workspace / "in.webm"
        source.write_bytes(recording)
        output = workspace / "out.mp4"

        # Fixed argv, no shell, and both filenames are ones this function wrote. `cwd` is the
        # temporary directory so nothing in the command is an absolute path.
        completed = _run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",
                # **A demuxer flag, so it goes before `-i`.** `MediaRecorder` writes a WebM
                # whose first cluster can carry no presentation timestamp at all; without
                # this ffmpeg starts the output clock at whatever it finds and the first
                # fraction of a second of the card is trimmed off the front.
                "-fflags",
                "+genpts",
                "-i",
                source.name,
                *_ENCODE,
                output.name,
            ],
            workspace,
        )
        if not completed.ok:
            raise TranscodeError(completed.why)
        if not output.exists() or not output.stat().st_size:
            # An exit code of zero and no file is a real ffmpeg outcome, not a theoretical one.
            raise TranscodeError("ffmpeg exited cleanly and wrote no file.")
        return output.read_bytes()


def probe(data: bytes) -> dict[str, object]:
    """What a finished file actually is, per ffprobe: codec, pixel format, duration, streams.

    **Called on every upload**, by `renders._check_length`, which compares the duration back
    against the scene graph — and by the tests, which assert on codec, pixel format and stream
    count. Asserting on the argv would only prove the argv; this is the property a platform's
    decoder actually reads.

    Returns `{}` rather than raising when ffprobe cannot answer, and a `None` duration when the
    container carries none, so a caller can say "unreadable" rather than crash. `renders.py`
    treats both as *not a refusal*, deliberately.
    """
    with tempfile.TemporaryDirectory(prefix="rascal-probe-") as directory:
        workspace = Path(directory)
        path = workspace / "probe.mp4"
        path.write_bytes(data)
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "stream=codec_type,codec_name,pix_fmt,width,height:format=duration",
                    "-of",
                    "json",
                    path.name,
                ],
                cwd=workspace,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
                stdin=subprocess.DEVNULL,
            )
        except (subprocess.TimeoutExpired, OSError):
            return {}
    if result.returncode != 0:
        return {}
    try:
        parsed = json.loads(result.stdout)
    except ValueError:
        return {}
    streams = parsed.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), {})
    duration = (parsed.get("format") or {}).get("duration")
    return {
        "codec_name": video.get("codec_name"),
        "pix_fmt": video.get("pix_fmt"),
        "width": video.get("width"),
        "height": video.get("height"),
        "audio_streams": sum(1 for s in streams if s.get("codec_type") == "audio"),
        "duration_seconds": float(duration) if duration not in (None, "N/A") else None,
    }


class _Result:
    __slots__ = ("ok", "why")

    def __init__(self, ok: bool, why: str) -> None:
        self.ok = ok
        self.why = why


def _run(command: list[str], cwd: Path) -> _Result:
    """Run ffmpeg and turn whatever happened into one sentence. Never raises.

    **`stderr`'s last line, not all of it.** ffmpeg writes paragraphs and the useful part is
    the last thing it said before giving up; the whole thing on a render row is a stack trace
    by another name, which `errors.py` forbids for the same reason.

    `stdin` is closed rather than inherited. ffmpeg reads the console for interactive keys, and
    a copy of it inside a web server sharing the process's stdin is a way to lose bytes that
    belong to something else — `-nostdin` is in the argv and this is the belt to that brace.
    """
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return _Result(
            False,
            f"ffmpeg did not finish within {TIMEOUT_SECONDS} seconds and was stopped. "
            "Nothing was stored.",
        )
    except OSError as error:
        return _Result(False, f"ffmpeg could not be started: {error.strerror or error}.")
    if result.returncode == 0:
        return _Result(True, "")
    tail = next(
        (line.strip() for line in reversed((result.stderr or "").splitlines()) if line.strip()),
        "",
    )
    return _Result(
        False,
        f"ffmpeg failed (exit {result.returncode})" + (f": {tail[:300]}" if tail else "."),
    )


__all__ = [
    "EBML_MAGIC",
    "MAX_RECORDING_BYTES",
    "TIMEOUT_SECONDS",
    "TranscodeError",
    "available",
    "probe",
    "to_mp4",
]
