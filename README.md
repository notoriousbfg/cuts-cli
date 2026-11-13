# cuts

A video editor with no window. A project is one JSON file of tracks, clips, titles and
transitions; `cuts` works out the timeline and has ffmpeg render it. It is meant to be
driven by an agent: every command prints JSON, every problem comes back with the JSON
path it was found at, and the edit can be looked at as stills before it is exported.

It is the companion to [reel](https://github.com/notoriousbfg/reel-cli), which records
the footage.

## Install

```sh
brew install ffmpeg
swift build -c release
rm -f ~/.local/bin/cuts && cp .build/release/cuts ~/.local/bin/
```

Requires macOS 14+ and Swift 6. Titles are drawn with Core Text, so the stock Homebrew
ffmpeg (which has no `drawtext`) is all that is needed. `CUTS_FFMPEG` and `CUTS_FFPROBE`
point at other builds.

## The loop

```sh
cuts probe footage/*.mp4                  # what is there: duration, size, frame rate
cuts check film.json                      # every problem, with its JSON path
cuts plan film.json                       # where each clip landed, in seconds
cuts sheet film.json -o sheet.png         # the edit as a grid of stills
cuts frame film.json --at title.start+1 -o frame.png
cuts render film.json --draft             # half size, fast
cuts render film.json                     # the real thing
```

With no times given, `sheet` shows the middle of every clip and of every transition,
which is where edits go wrong. Stills are rendered small and skip clips outside the
times asked for, so a sheet takes a few seconds.

## A project

```json
{
  "output": { "path": "out/film.mp4", "width": 1920, "height": 1080, "fps": 30, "background": ["#23262f", "#0e0f13"] },
  "media": { "journal": "footage/journal.mp4", "cards": "footage/cards.mp4" },
  "styles": { "caption": { "size": 34, "position": [0.5, 0.94], "fadeIn": 0.3, "fadeOut": 0.3 } },
  "tracks": [
    { "id": "main", "clips": [
      { "id": "title", "text": ["Grasmere", { "text": "A writing app", "size": 32, "gap": 20 }], "size": 160, "duration": 3 },
      { "id": "journal", "src": "journal", "in": 2.6, "out": 10.4, "scale": 0.84, "radius": 14, "shadow": true, "transition": "crossfade" },
      { "id": "cards", "src": "cards", "speed": 1.5, "transition": { "type": "slideleft", "duration": 0.6 } }
    ] },
    { "id": "captions", "clips": [
      { "style": "caption", "text": "A journal entry", "start": "journal.start+0.8", "end": "journal.end-0.8" }
    ] }
  ]
}
```

- **Tracks are layers.** The first is at the back. A track plays one clip at a time and is
  transparent where it has none.
- **Clips follow each other.** Without a `start`, a clip begins where the one before it ends.
  A `transition` overlaps the two, so the timeline shortens by its length.
- **Times can name clips.** `"start": "journal.start+0.8"` keeps a caption with its clip
  however the clips before it are re-trimmed.
- **A clip is a file, a fill or text.** All three take the same timing, fades, transitions and
  opacity; files also take `fit`, `scale`, `position`, `crop`, `radius` and `shadow`.
- **Sound** from video and audio files is mixed, with `volume`, `mute`, fades, and a
  crossfade wherever the picture has a transition.

`cuts format` prints the whole reference; `cuts transitions` lists the transition names.

## Demo

`demo/demo.json` cuts four Grasmere screen recordings into a 33-second film: a title card,
four different transitions, captions tied to their clips, and a dark-theme
picture-in-picture on its own track. It expects the recordings in
`../grasmere-app-site/media`.

```sh
cuts render demo/demo.json                # writes demo/out/grasmere-demo.mp4
```

## How it renders

One ffmpeg run. Each clip becomes a canvas-sized stream with alpha and an exact number of
frames; a track joins its clips with `concat` (cuts), `xfade` (transitions) and transparent
filler (gaps); the tracks are overlaid on the background in order. `cuts plan --command`
prints the ffmpeg command.

## Not there yet

Keyframed moves and zooms (reel's `edit` does zooms on a single recording), animated text
beyond fades and transitions, subtitles from a file, and rendering only part of the timeline.

## License

[MIT](LICENSE).
