let formatReference = #"""
CUTS PROJECT FILE (JSON)

{
  "version": 1,
  "output":  { "path": "out/film.mp4", "width": 1920, "height": 1080, "fps": 30,
               "background": "#101014", "codec": "h264", "crf": 18 },
  "media":   { "journal": "footage/journal.mp4" },
  "styles":  { "caption": { "font": "Helvetica Neue", "size": 44, "position": [0.5, 0.9] } },
  "tracks":  [ { "id": "main", "clips": [ … ] }, { "id": "titles", "clips": [ … ] } ]
}

Paths are relative to the project file. Unknown keys are errors, so typos are caught;
"notes" is allowed on the project, a track or a clip for your own remarks.

OUTPUT
  path                 where `cuts render` writes (or pass -o)
  width, height, fps   the canvas; default 1920 × 1080 at 30
  background           what shows where no clip covers the frame: a colour, or [from, to] for a gradient
  codec                "h264" (default) or "hevc"
  crf                  quality, lower is better (default 18 for h264, 22 for hevc)

MEDIA
  Optional short names for files. A clip's "src" may be a name from here or a path.

TRACKS
  Tracks are layers. The first is at the back; each later track is drawn over the ones before.
  A track holds clips in order, one at a time. Where a track has no clip it is transparent.
  id        a name (default track1, track2, …)
  enabled   false leaves the track out of the render
  volume    multiplies the volume of every clip on the track
  clips     the clips, in timeline order

CLIPS
  Each clip has exactly one of:
    "src"   a video, image or audio file
    "fill"  a colour, or [from, to] / {"gradient": [from, to], "angle": 90} filling the frame
    "text"  a title: a string, or an array of lines (see TEXT)

  Timing
    id          a name others can refer to (default <track id>.<n>, counting from 1)
    start       when it begins. Left out, it follows the clip before it on the track.
                Seconds, or another clip's edge: "intro.end", "demo.start+1.5", "demo.end-2"
    in, out     the part of the source to use, in source seconds (video and audio)
    duration    how long it lasts on the timeline. Default: the trimmed source at its speed;
                4 s for images, fills and text. A video asked to run longer holds its last frame.
    end         instead of duration: a time or clip edge at which it ends
    speed       playback speed, 0.1–20 (sound keeps its pitch)

  Joins
    transition  how it comes in over the clip before it: a name, or {"type": name, "duration": seconds}
                (default 0.5 s). The two clips overlap for the transition, so the timeline gets
                shorter by its duration. With nothing before it on the track, it comes in over the
                layers below. Names: `cuts transitions`.
    fadeIn, fadeOut   seconds to fade from / to transparent (to the background, on the bottom track)

  Picture
    fit         "contain" (default), "cover", "stretch", or "none" (source pixels)
    scale       multiplies the fitted size: 0.8 leaves a margin, 0.3 makes a picture-in-picture
    position    where the clip's anchor goes on the canvas: [x, y] from 0–1, or "center",
                "top-left", "bottom-right" … (default center)
    anchor      which point of the clip is put at position (default center)
    crop        [x, y, width, height] of the source to keep, as fractions 0–1
    radius      rounded corners, in output pixels
    shadow      true, or {"blur", "x", "y", "color", "opacity"}
    opacity     0–1

  Sound
    volume      multiplier (default 1)
    mute        true drops the clip's sound
    A transition crossfades the sound of the two clips; fadeIn / fadeOut fade it too.

TEXT
  "text": "One line"
  "text": ["Line one", {"text": "A smaller line", "size": 40, "color": "#ffffffaa", "gap": 12}]

  On the clip, or on a single line to override it:
    font        a family ("Helvetica Neue", "New York") or PostScript name; default: the system font
    fontFile    a .ttf / .otf / .ttc file instead
    size        in output pixels (default 64)
    weight      ultralight thin light regular medium semibold bold heavy black
    italic, color, tracking (extra space between letters, px), lineHeight (default 1.15)
    gap         (lines only) extra space above the line, px
  On the clip only:
    align       left | center | right
    maxWidth    widest the text may run before wrapping, as a fraction of the frame (default 0.84)
    box         {"color", "padding", "radius"}: a panel behind the text
    background  a colour or gradient filling the whole frame behind the text (a title card)
    shadow      a drop shadow on the letters
    position, anchor, opacity, fadeIn, fadeOut, transition   as for any clip

STYLES
  "styles" names sets of clip keys. A clip with "style": "caption" starts from that set;
  its own keys win.

COLOURS
  "#rgb", "#rrggbb", "#rrggbbaa", "black", "white", "transparent".

COMMANDS
  cuts check project.json                 every problem, with its JSON path
  cuts plan project.json                  where each clip landed, in seconds
  cuts sheet project.json -o sheet.png    frames of the edit in a grid (mid-clip and mid-transition)
  cuts frame project.json --at 3.2 -o f.png
  cuts render project.json [--draft]
  cuts probe file.mp4                     duration, size, frame rate of a source
"""#
