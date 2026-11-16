"""Helpers for rendering experiment-task videos: skia frames -> x264 MP4, speed control, PNG stills, decode-back checks.

Copy this file next to the project's render script (for example scripts/task_videos/) so the repo can rebuild
its videos without the skill. Pin the dependencies in the render script's PEP 723 header:

    # dependencies = ["skia-python==144.1", "imageio-ffmpeg==0.8.1", "numpy==2.5.4"]

A scene is any object with `.dur` (seconds of task time) and `.draw(canvas, t)`. `Sequence` plays scenes back
to back, `render` turns a scene into an MP4 at any speed, `stills` writes PNGs at chosen task times, and
`decode` + `runs` read an encoded MP4 back so you can check what people will actually see.
"""
import math
import os
import subprocess

import imageio_ffmpeg
import numpy as np
import skia

W, H, FPS = 1920, 1080, 60


# ----------------------------------------------------------------- PsychoPy timing and units
def flip_locked_duration(wait_s, hz, overhead_s=0.001):
    """Time on screen for `core.wait(wait_s)` followed by `win.flip()`, starting from a flip.

    The flip blocks until the next vsync after the wait (plus a little code overhead), so the phase lasts a whole
    number of refreshes. When wait_s * hz is a whole number (0.1 s at 60 Hz = 6 refreshes) the overhead usually
    pushes the flip one refresh later (7). Confirm against logged intervals before trusting either case.
    """
    return math.ceil((wait_s + overhead_s) * hz) / hz


_NAMED = {'black': (0, 0, 0), 'white': (255, 255, 255), 'gray': (128, 128, 128), 'grey': (128, 128, 128),
          'red': (255, 0, 0), 'green': (0, 128, 0), 'blue': (0, 0, 255), 'yellow': (255, 255, 0)}


def psychopy_color(color, space='rgb'):
    """A PsychoPy color as 0-255 (r, g, b).

    'rgb' is PsychoPy's default space and runs -1..1, so (0, 0, 0) is mid-gray, not black. 'rgb255' is 0-255,
    'rgb1' is 0-1. Named colors follow psychopy.colors.colorNames (the SVG list); only a few common ones are here.
    """
    if isinstance(color, str):
        if color.startswith('#'):
            return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))
        if color.lower() in _NAMED:
            return _NAMED[color.lower()]
        raise ValueError(f'look up {color!r} in psychopy.colors.colorNames')
    if isinstance(color, (int, float)):
        color = (color, color, color)
    if space == 'rgb':
        return tuple(round((v + 1) * 127.5) for v in color)
    if space == 'rgb255':
        return tuple(round(v) for v in color)
    if space == 'rgb1':
        return tuple(round(v * 255) for v in color)
    raise ValueError(f'unsupported color space {space!r}')


def blend(fg, bg, alpha):
    """What an `opacity=alpha` stimulus looks like over a uniform background, in 0-255 RGB."""
    return tuple(round(b + (f - b) * alpha) for f, b in zip(fg, bg))


def to_canvas(x, y, win_w, win_h):
    """PsychoPy pixel coordinates (origin at screen center, +y up) -> canvas pixels (origin top-left, +y down)."""
    return win_w / 2 + x, win_h / 2 - y


def deg2pix(deg, distance_cm, width_cm, width_px):
    """PsychoPy 'deg' units (small-angle: cm = deg * distance * 0.017455). 'degFlat' uses tan instead."""
    return deg * distance_cm * 0.017455 * width_px / width_cm


def pix2deg(pix, distance_cm, width_cm, width_px):
    return pix * width_cm / width_px / (distance_cm * 0.017455)


# ----------------------------------------------------------------- scenes, rendering, stills
class Sequence:
    """Scenes played back to back; behaves like one scene."""

    def __init__(self, scenes):
        self.scenes = list(scenes)
        self.starts = np.cumsum([0.0] + [s.dur for s in self.scenes])
        self.dur = float(self.starts[-1])

    def locate(self, t):
        i = min(int(np.searchsorted(self.starts, t, side='right')) - 1, len(self.scenes) - 1)
        return i, self.scenes[i], t - self.starts[i]

    def draw(self, c, t):
        _, scene, lt = self.locate(t)
        scene.draw(c, lt)


def draw_into(buf, scene, t, overlay=None, background=skia.ColorWHITE):
    surface = skia.Surface(buf, colorType=skia.kRGBA_8888_ColorType)
    with surface as c:
        c.clear(background)
        scene.draw(c, t)
        if overlay:
            overlay(c)


def encode(out, nframes, draw_frame, w=W, h=H, fps=FPS, crf=14):
    """Pipe nframes RGBA frames (draw_frame(i, buf) fills buf in place) through x264 into an MP4.

    yuv420p, High profile, BT.709 tags and +faststart keep the file playable in Keynote, PowerPoint, QuickTime and
    browsers without color shifts. crf 14 with -tune animation keeps thin lines and text clean.
    """
    buf = np.zeros((h, w, 4), np.uint8)
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgba',
           '-s', f'{w}x{h}', '-r', str(fps), '-i', '-',
           '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p', '-c:v', 'libx264', '-preset', 'slow',
           '-crf', str(crf), '-tune', 'animation', '-profile:v', 'high', '-colorspace', 'bt709', '-color_primaries',
           'bt709', '-color_trc', 'bt709', '-color_range', 'tv', '-movflags', '+faststart', str(out)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in range(nframes):
        draw_frame(f, buf)
        proc.stdin.write(buf.tobytes())
        if f % 600 == 0:
            print(f'{out}: frame {f}/{nframes}', flush=True)
    proc.stdin.close()
    if proc.wait() != 0:
        raise RuntimeError(f'ffmpeg failed writing {out}')


def render(out, scene, speed=1.0, overlay=None, background=skia.ColorWHITE, w=W, h=H, fps=FPS):
    """Frame f shows task time f / fps * speed, so speed 0.5 doubles the frame count and every clock stays in task time."""
    nframes = int(round(scene.dur / speed * fps))
    encode(out, nframes, lambda f, buf: draw_into(buf, scene, f / fps * speed, overlay, background), w, h, fps)
    print(f'wrote {out} ({nframes / fps:.2f} s video, {scene.dur:.2f} s task time, speed {speed:g}, {nframes} frames)')
    return nframes


def stills(scene, times, outdir, prefix='frame', overlay=None, background=skia.ColorWHITE, w=W, h=H):
    """PNG stills at task times; look at a few of these before encoding long videos."""
    os.makedirs(outdir, exist_ok=True)
    buf = np.zeros((h, w, 4), np.uint8)
    paths = []
    for t in times:
        draw_into(buf, scene, float(t), overlay, background)
        p = os.path.join(outdir, f'{prefix}_{float(t):07.3f}.png')
        skia.Image.fromarray(buf.copy(), colorType=skia.kRGBA_8888_ColorType).save(p, skia.kPNG)
        paths.append(p)
    return paths


# ----------------------------------------------------------------- reading the encoded file back
def decode(path, w=W, h=H, start=None, dur=None):
    """Yield decoded RGB frames (h, w, 3) from an MP4, optionally from `start` seconds for `dur` seconds."""
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), '-loglevel', 'error']
    if start is not None:
        cmd += ['-ss', f'{start:.4f}']
    cmd += ['-i', str(path)]
    if dur is not None:
        cmd += ['-t', f'{dur:.4f}']
    proc = subprocess.Popen(cmd + ['-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
    n = w * h * 3
    while True:
        b = proc.stdout.read(n)
        if len(b) < n:
            break
        yield np.frombuffer(b, np.uint8).reshape(h, w, 3)
    proc.wait()


def runs(states, fps=FPS, t0=0.0):
    """Collapse per-frame labels into [label, start_s, end_s] runs (video seconds)."""
    out = []
    for i, s in enumerate(states):
        t = t0 + i / fps
        if out and out[-1][0] == s:
            out[-1][2] = t + 1 / fps
        else:
            out.append([s, t, t + 1 / fps])
    return out
