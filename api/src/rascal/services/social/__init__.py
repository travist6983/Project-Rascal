"""The social studio: art direction from Claude, pixels from a template or a provider.

**The load-bearing fact, stated once here so no module below has to argue it again: Anthropic
has no image or video endpoint.** Claude takes text and images in and produces text out. So a
studio built on one Anthropic key gets art direction, copy, captions, alt text, image briefs
and scene graphs — all of which it is genuinely good at — and the pixels come from somewhere
else: a brand-card template drawn on a canvas in the browser, or a third-party renderer that
is unconfigured until somebody adds a key.

**Video is the same sentence, and since phase 120 it is true of video too.** No vendor
generates video for this product. Claude writes a typed scene graph — cards, copy, durations,
transitions, every value from a closed set — the browser draws it with the same renderer that
draws a still and records the canvas, and `transcode.py` re-encodes the recording into the
H.264 MP4 a platform will accept. The one thing that was bought before is not bought now.

`brand.py` is what Claude is told. `director.py` is the call. `renderers.py` is the pixels.
`scenes.py` derives the caption track from the graph. `transcode.py` is ffmpeg. `studio.py`
is storage and the one guard that matters — D7's cap on how much of the mission library may
be put in public.
"""
