"""The social studio: art direction from Claude, pixels from a template or a provider.

**The load-bearing fact, stated once here so no module below has to argue it again: Anthropic
has no image or video endpoint.** Claude takes text and images in and produces text out. So a
studio built on one Anthropic key gets art direction, copy, captions, alt text, image briefs
and shot lists — all of which it is genuinely good at — and the pixels come from somewhere
else: a brand-card template drawn on a canvas in the browser, or a third-party renderer that
is unconfigured until somebody adds a key.

`brand.py` is what Claude is told. `director.py` is the call. `renderers.py` is the pixels.
`studio.py` is storage and the one guard that matters — D7's cap on how much of the mission
library may be put in public.
"""
