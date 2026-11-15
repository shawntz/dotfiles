#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["skia-python==144.1", "imageio-ffmpeg==0.8.1", "numpy==2.5.4"]
# ///
"""Smallest end-to-end template: one made-up trial as participant view + under-the-hood timeline, with a check.

Keep the structure and replace the contents. EVENTS becomes the logged flip times of a real trial (from the
project's extraction JSON), draw_participant becomes the task's stimuli, and the right panel grows into the
real signal, thresholds, log and CSV cards. One screen_state(t) function feeds the video, the stills and the
decode-back check, so all three always agree.

    uv run example_render.py video OUT.mp4 [--speed 0.5]
    uv run example_render.py frames OUTDIR t1 t2 ...
    uv run example_render.py check OUT.mp4 [--speed 0.5]
"""
import sys
from pathlib import Path

import skia

sys.path.insert(0, str(Path(__file__).parent))
import video_kit as K  # noqa: E402

HZ = 85.0                 # from the logs: a screen_hz column, win.getActualFrameRate(), or inter-flip intervals
SCREEN = (1024, 768)      # task window, pixels
PH = K.flip_locked_duration(0.1, HZ)   # each cue phase: core.wait(0.1) then win.flip() -> 9 refreshes at 85 Hz

# Screen changes, seconds from trial start. In a real project these are logged message times; only the cue's
# inner phases, which the task never logged, are rebuilt from the code and the refresh rate.
CUE0 = 1.0
EVENTS = [('fix', 0.0), ('ring', CUE0), ('fix', CUE0 + PH), ('ring', CUE0 + 2 * PH), ('fix', CUE0 + 3 * PH),
          ('probe', CUE0 + 4 * PH + 0.5), ('fix', CUE0 + 4 * PH + 0.5 + 0.8)]
SEGMENTS = [('ITI', 0.0, CUE0, '#cd83ef'), ('cue', CUE0, CUE0 + 4 * PH, '#ed4c89'),
            ('post', CUE0 + 4 * PH, CUE0 + 4 * PH + 0.5, '#d1ccc6'),
            ('probe', CUE0 + 4 * PH + 0.5, CUE0 + 4 * PH + 1.3, '#f8933f')]
MESSAGES = [(0.0, 'FIX_S'), (CUE0, 'TRIG_S'), (CUE0 + 4 * PH, 'FIX_POST'), (CUE0 + 4 * PH + 0.5, 'PROBE_S'),
            (CUE0 + 4 * PH + 1.3, 'KEY o  rt 0.800')]
TRIAL_END = EVENTS[-1][1] + 0.7

LX, LY, SC = 56, 180, 0.78                    # participant screen origin and scale on the 1920 x 1080 frame
RX0, RX1 = 925, 1864                          # right column


def typeface(*names):
    for n in names:
        tf = skia.FontMgr().matchFamilyStyle(n, skia.FontStyle())
        if tf:
            return tf
    return skia.Typeface.MakeDefault()


TIMES = typeface('Times', 'Times New Roman')            # the task's font='Times'
SANS = typeface('Helvetica Neue', 'Arial', 'DejaVu Sans')
MONO = typeface('Menlo', 'DejaVu Sans Mono')


def paint(rgb, alpha=1.0, stroke=None):
    if isinstance(rgb, str):
        rgb = K.psychopy_color(rgb)
    p = skia.Paint(AntiAlias=True, Color=skia.Color4f(*(v / 255 for v in rgb), alpha))
    if stroke:
        p.setStyle(skia.Paint.kStroke_Style)
        p.setStrokeWidth(stroke)
    return p


def text(c, s, x, y, tf, size, color='#222222', align='l'):
    f = skia.Font(tf, size)
    if align == 'r':
        x -= f.measureText(s)
    c.drawString(s, x, y, f, paint(color))


def screen_state(t):
    state = EVENTS[0][0]
    for s, t0 in EVENTS:
        if t >= t0:
            state = s
    return state


def draw_participant(c, x, y, s, state):
    w, h = SCREEN
    c.save()
    c.translate(x, y)
    c.scale(s, s)
    c.clipRect(skia.Rect.MakeWH(w, h))
    c.drawRect(skia.Rect.MakeWH(w, h), paint(K.psychopy_color((1, 1, 1))))   # Window(color=(1, 1, 1)), 'rgb' space
    cx, cy = K.to_canvas(0, 0, w, h)
    if state in ('fix', 'ring'):
        if state == 'ring':
            # visual.Circle(radius=75, lineWidth=2, lineColor='black', opacity=0.3, fillColor=None)
            c.drawCircle(cx, cy, 75, paint('black', 0.3, stroke=2))
        # visual.TextStim(text='+', font='Times', height=36, color='black'): centered on its line box
        f = skia.Font(TIMES, 36)
        m = f.getMetrics()
        c.drawString('+', cx - f.measureText('+') / 2, cy - (m.fAscent + m.fDescent) / 2, f, paint('black'))
    elif state == 'probe':
        # stands in for visual.ImageStim(size=300); with a real image use c.drawImageRect at native size
        c.drawRect(skia.Rect.MakeXYWH(cx - 150, cy - 150, 300, 300),
                   paint(K.psychopy_color((0.6, -0.6, -0.6))))
    c.restore()
    c.drawRect(skia.Rect.MakeXYWH(x, y, w * s, h * s), paint('#bbbbbb', stroke=1))


def draw_timeline(c, t):
    y0, y1 = 230, 270
    span = TRIAL_END
    tx = lambda v: RX0 + (RX1 - RX0) * v / span
    for name, a, b, col in SEGMENTS:
        c.drawRect(skia.Rect.MakeLTRB(tx(a), y0, tx(b), y1), paint(col, 1.0 if a <= t else 0.35))
        text(c, name, tx(a) + 6, y1 + 26, SANS, 18)
    c.drawRect(skia.Rect.MakeXYWH(tx(min(t, span)) - 1, y0 - 12, 2, y1 - y0 + 24), paint('#222222'))
    y = 380
    text(c, 'Messages the task logged', RX0, y, SANS, 20, '#777777')
    for tm, msg in MESSAGES:
        if t >= tm:
            y += 34
            text(c, f'{tm:7.3f}  {msg}', RX0, y, MONO, 20)
    text(c, f'screen: {screen_state(t)}', RX0, 820, SANS, 34)


class TrialScene:
    dur = TRIAL_END

    def draw(self, c, t):
        text(c, 'Example trial (template)', LX, 80, SANS, 40)
        text(c, f't = {t:.3f} s', RX1, 80, MONO, 30, align='r')
        draw_participant(c, LX, LY, SC, screen_state(t))
        draw_timeline(c, t)


def speed_badge(speed):
    def overlay(c):
        if speed == 1:
            return
        label = f'{speed:g}× SPEED'
        f = skia.Font(SANS, 18)
        w = f.measureText(label) + 30
        r = skia.Rect.MakeLTRB(RX1 - w, 10, RX1, 42)
        c.drawRRect(skia.RRect.MakeRectXY(r, 16, 16), paint('#222222'))
        c.drawString(label, RX1 - w + 15, 32.5, f, paint('white'))
    return overlay


def classify(frame):
    """Participant-screen state from three pixel probes on the decoded frame."""
    cx, cy = LX + SCREEN[0] / 2 * SC, LY + SCREEN[1] / 2 * SC
    inner = frame[int(cy), int(cx + 100 * SC)]          # inside the probe square, outside the ring
    edge = frame[int(cy), int(cx + 75 * SC)]            # on the r = 75 ring
    if inner[0] > 150 and inner[1] < 90:
        return 'probe'
    return 'ring' if edge.mean() < 235 else 'fix'


def check(path, speed):
    rs = K.runs(classify(f) for f in K.decode(path))
    print(f'{"state":6s} {"video start":>11s} {"task time":>9s} {"logged":>8s} {"diff ms":>8s}')
    worst = 0.0
    for (s, a, b), (s_log, t_log) in zip(rs, EVENTS):
        task = a * speed
        diff = (task - t_log) * 1000
        worst = max(worst, abs(diff))
        flag = '' if s == s_log else f'   <- expected {s_log}'
        print(f'{s:6s} {a:11.3f} {task:9.3f} {t_log:8.3f} {diff:8.1f}{flag}')
    if len(rs) != len(EVENTS):
        print(f'run count {len(rs)} != logged changes {len(EVENTS)}')
    print(f'max |video - logged| = {worst:.1f} ms task time (one video frame = {1000 * speed / K.FPS:.1f} ms task time)')


def main():
    speed = 1.0
    if '--speed' in sys.argv:
        i = sys.argv.index('--speed')
        speed = float(sys.argv[i + 1])
        del sys.argv[i:i + 2]
    mode = sys.argv[1]
    scene = TrialScene()
    if mode == 'video':
        K.render(sys.argv[2], scene, speed, overlay=speed_badge(speed))
    elif mode == 'frames':
        for p in K.stills(scene, sys.argv[3:], sys.argv[2], 'trial'):
            print(p)
    elif mode == 'check':
        check(sys.argv[2], speed)


if __name__ == '__main__':
    main()
