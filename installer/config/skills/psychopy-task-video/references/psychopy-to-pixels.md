# PsychoPy to pixels

How to redraw a PsychoPy screen on a canvas so it matches what the participant saw. Defaults below were checked against the PsychoPy 2023.1.3 source. Behavior changes between releases, so find out which version ran (a `psychopyVersion` column in Builder CSVs, the `.log` header, or the lab's requirements file) and read that version's source in `psychopy/visual/` when a detail matters. `pip download psychopy==<version> --no-deps` gets the source zip without installing it.

`scripts/video_kit.py` has helpers for the conversions here: `psychopy_color`, `blend`, `to_canvas`, `deg2pix`, `pix2deg`, `flip_locked_duration`.

## Contents

- Window and coordinates
- Units
- Colors and opacity
- Shapes
- Images
- Text
- Timing
- Things a video can't reproduce

## Window and coordinates

- Read the `visual.Window(...)` call: `size`, `units`, `color`, `colorSpace`, `fullscr`, `monitor`. The window size in pixels is the participant's screen. Draw the participant view in those pixels and scale the whole thing uniformly onto the video frame.
- PsychoPy puts the origin at the screen center with +y up. Canvas libraries put it top-left with +y down. Convert with `to_canvas(x, y, win_w, win_h)`. Getting the y sign wrong silently mirrors anything placed above or below center.
- `pos` is the stimulus center unless an anchor says otherwise.

## Units

| units | 1 unit in pixels |
|---|---|
| `pix` | 1 |
| `height` | window height |
| `norm` | half the window width (x) or half the window height (y) |
| `cm` | width_px / width_cm from the Monitor Center entry |
| `deg` | `deg * distance_cm * 0.017455 * width_px / width_cm` (small-angle approximation) |
| `degFlat`, `degFlatPos` | tan-based, so eccentric positions spread out; compute per vertex |

`deg` needs the monitor's width in cm and the viewing distance. They live in the Monitor Center profile, not in the script. If you can't find them, ask, and state any assumption on screen or in the README. Report visual angles in callouts when they help (for example, "ring: 4° across at 57 cm").

## Colors and opacity

- The default `colorSpace` is `'rgb'`, which runs from -1 to 1. `(0, 0, 0)` is mid-gray (128), not black. `(-1, -1, -1)` is black and `(1, 1, 1)` is white.
- `'rgb255'` is 0-255 and `'rgb1'` is 0-1. Hex strings are hex. Named colors come from `psychopy.colors.colorNames`, which uses the SVG list in -1..1 form. For example `'gray'` is 128, `'darkgray'` is 169, and `'green'` is (0, 128, 0).
- A stimulus's `colorSpace` can differ from the window's. Check each one.
- `opacity` alpha-blends over whatever is underneath. A black line at opacity 0.3 on white shows as gray 179. Put that number in a callout, because "30% opacity" means little to an audience and "gray 179 on 255" can be checked.
- `contrast` on ImageStim and GratingStim scales around mid-gray in the -1..1 space. It does not scale toward black.

## Shapes

- `visual.Circle`, `Rect`, `Polygon`, `ShapeStim`: `lineColor` (alias `borderColor`), `fillColor` (`None` means no fill), `lineWidth`, `opacity`.
- `lineWidth` defaults to 1.5. In 2023.1 and earlier the border is drawn with `glLineWidth`, so `lineWidth` is in screen pixels whatever the stimulus units. Check this in the source for newer versions.
- `Circle(edges="circle")` picks enough edges to look smooth, so a true circle is fine. A small integer `edges` gives a visible polygon, so draw that polygon.
- Draw thin lines at 1:1 scale on integer-aligned centers in close-up shots so the line stays crisp. At a 0.78 overview scale, a 2-px line becomes about 1.6 px and looks lighter. That's acceptable for the overview, but the close-up should show the real thing.

## Images

- `visual.ImageStim(image, size=None)` shows the file at its native pixel size in `pix` units. With an explicit `size` it is resampled.
- `interpolate=False` is the default, which means nearest-neighbor scaling when the size differs from the file. Match it: draw with nearest sampling, or with linear sampling only when the task set `interpolate=True`.
- Use the actual stimulus file from the task repo. If the analysis repo has a copy, compare checksums before you trust it.
- Check `flipHoriz`, `flipVert`, `mask` and `ori` in the call.

## Text

- `visual.TextStim` (pyglet backend) loads the font at `int(height_in_pixels)` points at 72 dpi. So draw with a font size equal to the pixel height, truncated to an integer.
- Default anchors are center/center. Center the string on its line box: `y = cy - (ascent + descent) / 2` with skia metrics (ascent is negative in skia). This matches PsychoPy's placement of a fixation `+`.
- `font=""` lets pyglet pick the system default, which depends on the machine that ran the task. A named font that isn't installed falls back silently. Look for font warnings in the `.log`, and use the named font (for example Times for `font='Times'`).
- `TextBox2` is a different class with its own layout: `letterHeight`, padding, and an anchor that defaults to the box. Read its call carefully if the task uses it.
- Default heights, when `height` is omitted, depend on units (`defaultLetterHeight` in `visual/text.py`).

## Timing

- `win.flip()` blocks until the next vertical refresh, and everything drawn appears together at that refresh.
- `core.wait(d)` followed by `win.flip()` holds the previous screen for `ceil((d + overhead) * hz)` refreshes. When `d * hz` is a whole number (0.1 s at 60 Hz), the overhead usually adds one more refresh (7 instead of 6). When it isn't a whole number (0.1 s at 85 Hz = 8.5), the result is reliably `ceil(d * hz)` (9 refreshes, 106 ms). Confirm against logged intervals.
- A frame-counting loop (`for i in range(n): draw; win.flip()`) lasts exactly n refreshes unless frames dropped. Check `win.nDroppedFrames` or the log.
- A clock loop (`while clock.getTime() < d: draw; flip`) usually ends one refresh past `d`.
- A keypress ends a stimulus at the first flip after the key. The RT in the CSV is measured from whatever clock reset the task used, so read the code to see which flip that was.
- Eye-tracker or EEG messages sent right after `win.flip()` land a few ms after the real flip. Messages sent before the flip land up to one refresh early. `win.callOnFlip(...)` messages are locked to the flip. Find which pattern the task uses before you treat a message time as a flip time.
- Builder experiments write `<component>.started` and `<component>.stopped` columns that give per-trial onset and offset times.
- Get the refresh rate from the data: a `screen_hz` or `frameRate` column, `win.getActualFrameRate()` in the log, or the median interval between flip-locked messages. CRTs at 85 or 100 Hz are common in older labs, so don't assume 60.

## Things a video can't reproduce

Mention these when you report back, and in the talk if they matter:

- **Physical size.** 1:1 pixels match the task only on a display at native resolution with the same pixel pitch. A projector changes the size.
- **Luminance and gamma.** A gamma-calibrated CRT or a dark booth looks different from an sRGB video on a laptop.
- **Refresh timing.** A 60-fps video can't show 85-Hz phases exactly. Each state starts on the first video frame at or after its true time, so phases alternate between 100 and 117 ms where the CRT showed 106 ms. Slowed versions show the timing more finely (0.5× gives 8 ms steps of task time, 0.25× gives 4 ms).
