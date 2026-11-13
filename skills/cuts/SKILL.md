---
name: cuts
description: Edit video from the command line with the `cuts` CLI: join clips on tracks with titles, captions, transitions and sound, described in one JSON project file and rendered by ffmpeg. Use when asked to cut together, assemble or title a video from existing footage.
---

# cuts

`cuts` renders a JSON project file. Read `cuts format` first: it is the full reference and it changes.

## Loop

1. `cuts probe <files>` to learn each source's duration and size. Look at footage before trimming it
   (`reel sheet <file>` if reel is installed) so `in` / `out` are chosen from what is on screen.
2. Write the project. Give clips an `id`, and time captions and overlays from clip edges
   (`"start": "shot.start+0.8"`, `"end": "shot.end-0.8"`), not from seconds.
3. `cuts check project.json`. Fix every issue it lists; each has the JSON path.
4. `cuts sheet project.json -o sheet.png` and read the image. The default sheet shows the middle of every
   clip and transition. Use `--at shot.start+0.2,7.5` for particular moments and `cuts frame --at … -o f.png`
   for one frame at full size.
5. `cuts render project.json` only once the sheet is right. `--draft` is half size and quick.

## Things to know

- Tracks are layers, first at the back. One clip at a time per track; overlaps need another track.
- A transition shortens the timeline by its duration. `cuts plan` shows where everything landed.
- Screen recordings look best inset: `"scale": 0.84, "radius": 14, "shadow": true` over a gradient
  `output.background`. Put shared settings in `styles`.
- Text does not animate beyond `fadeIn` / `fadeOut` and transitions. Long text wraps at `maxWidth`.
- Unknown keys are errors. `"notes"` is the place for remarks.
