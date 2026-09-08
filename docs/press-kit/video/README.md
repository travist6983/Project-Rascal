# Demo video

`pocket-chronicle-demo.mp4` — 1080 × 1920, 30 fps, H.264, silent, 29.8 seconds. Rendered with the
marketing repo's Remotion "Showcase" composition (`Rascal-Marketing/video/src/Showcase.tsx`), so it
shares the site's cream paper, Nunito display type and thin device frame. Every clip is a real
screen recording of the app on an iPhone 17 Pro simulator; the two stills are real screenshots.

Scenes, in order:

1. Card — "Two prompts a day. A childhood you can find again." (2.0 s)
2. Clip — the Today board: a photo mission, a video mission, the question. (2.9 s)
3. Clip — a waiting voice prompt ("Record Wren counting as high as they can go.") is tapped, the
   recorder opens, recording runs with a live waveform, Finish. Played at 1.75×. (5.9 s)
4. Clip — Keep, the composer with the voice note attached under the prompt, Save. 1.5×. (3.0 s)
5. Still — the entry just recorded, open: waveform, 0:07, the transcript, "4 years, 2 months". (4.8 s)
6. Clip — the + button, Write, the date pill, the year wheel back to 2023, Sep 7 picked, a sentence
   typed, Save. Played at 3×. (6.8 s)
7. Still — the Timeline at 2023: "7 September 2023 · 1y 2m" with the entry that was just written. (2.4 s)
8. Card — "Pocket Chronicle. On the App Store." (2.0 s)

The transcript in scene 5 was written back through `PATCH /media/{id}/derived` — the same call the
phone makes after on-device transcription — because the Simulator cannot run Apple's on-device
speech model. On a real iPhone running iOS 26 the words appear on their own a few seconds after
saving. Everything else is the app doing exactly what it does.

## Raw recordings

`raw/` holds the untouched `simctl recordVideo` captures (re-encoded to constant 30 fps, 1206 × 2622),
in case you want a different cut: `01-today-board`, `02-voice-prompt-to-recording`,
`03-keep-and-save`, `05-backdate-to-2023`. (`04-transcript-detail` is the short take the still in
scene 5 replaced — the simulator's recorder kept missing the tap that opens the entry.)

## To re-render

```bash
cd Rascal-Marketing/video
npx remotion render src/index.ts Showcase out/demo.mp4 \
  --props=../../Project-Rascal/docs/press-kit/video/showcase-props.json \
  --public-dir=<a folder with recordings/v2-*.mp4, screens/demo-2023.png and fonts/*.woff2>
```

`showcase-props.json` is the scene list above; the clip names refer to trimmed clips cut from `raw/`
with ffmpeg (`-ss`/`-t`, `setpts=PTS/1.75` etc.). Scene lengths are seconds; a clip is cut to its
scene length, a still is held for it. Keep the total under 30.
