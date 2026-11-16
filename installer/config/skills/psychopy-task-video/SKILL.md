---
name: psychopy-task-video
description: Make faithful MP4 videos of a PsychoPy experiment for talks, lab meetings, posters, teaching or supplements. Each video shows what participants saw, frame-accurate to the task code and logs, next to what the code was doing at that moment (real-time signals, thresholds, branch decisions, the CSV columns each trial ends up with). The videos replay real logged trials for each condition, add slowed versions and zoomed close-ups of brief or faint stimuli, and check their timing by decoding the finished MP4. Use this whenever someone wants a video, animation, demo, screen capture or GIF of a task, trial sequence, paradigm or condition (cue, trigger, fixation, probe, mask, feedback), or wants to show how a closed-loop, eye-tracking, pupil, EEG or neurofeedback task works, even if they never say "PsychoPy". The same approach fits Psychtoolbox, jsPsych, OpenSesame and Presentation tasks, with their own flip and logging rules.
argument-hint: "[task repo or script] [data folder] [figure or figure code]"
---

# PsychoPy task videos

This skill turns an experiment's code and logs into talk-ready MP4s. The left side of each frame shows the participant's screen. The right side shows what the code was doing at that moment. The goal is one-to-one fidelity:

- every screen change sits at its real time
- every stimulus is drawn with the task's own parameters
- every number on screen comes from the data

That's why the work starts from the task code and the logs, not from the methods section or the figure. Methods and figures are summaries, and they often disagree with the code in small ways. Nobody catches those by animating the figure.

## What's in this skill

- `scripts/video_kit.py` has the shared pieces: skia frames piped to x264, speed control, PNG stills, decoding the MP4 back, and the PsychoPy unit, color and flip-timing helpers. Copy it into the project.
- `scripts/example_render.py` is a runnable one-trial template with a participant view, a timeline, a logged-message list, a speed badge, and a `check` mode that decodes the video and compares every screen change to its logged time. Start from it.
- `references/psychopy-to-pixels.md` covers how PsychoPy units, colors, opacity, shapes, images, text and flip timing map to canvas drawing, and what a video can't reproduce. Read it before drawing the participant screen.

## Workflow

### 1. Gather the sources and decide where things live

You need:

- **Task code.** Get the script that actually ran, its settings file and its stimuli. Analysis repos often don't include the task. If it's missing, ask for it (a git URL is enough). Clone it into the scratchpad, and check that its history matches the data-collection dates.
- **Design figure.** Get the illustration and the code that draws it. The video borrows its colors, fonts, labels and condition names, so it reads as the same study.
- **Logs.** Get the per-trial behavioral CSV, the PsychoPy `.log`, and any eye-tracker or EEG message files with timestamps. These are what let you place each screen change at its real time instead of its nominal duration.

Put the generating code in the project repo from the start, not in a temp folder. A sensible default is `scripts/task_videos/`, with outputs in `reports/videos/` or wherever the repo keeps figures. Code left in a scratch folder is easily lost when the session ends. Extracted participant data goes under a gitignored data path, such as `data/derivatives/task_videos/trials.json`. Check `.gitignore` to confirm it's covered.

### 2. Write the timing spec from the code

Read the trial routine top to bottom and list every screen state in order. For each one, note:

- what's drawn, with the exact stimulus parameters
- what starts it and what ends it: a fixed wait, a frame count, a keypress, a timeout, or a real-time decision
- which log message marks it, and whether that message is sent before or after the flip

Also list the work that happens while the screen doesn't change: sampling windows, baseline updates, threshold checks, counterbalancing or "balancer" logic, recycling rules. This is the under-the-hood content the user wants to show, and it often runs during a plain fixation cross.

Trace every branch the code can take, including the rare ones (missing data, timeouts, aborted and re-queued trials). Rare branches make good chapters because they're the hardest to explain with a static figure.

Don't trust nominal durations, because flips snap to the refresh. `core.wait(0.1)` followed by `win.flip()` on an 85-Hz CRT lasts 9 refreshes, which is 106 ms. `flip_locked_duration()` in the kit models this, and `references/psychopy-to-pixels.md` explains the cases. Get the refresh rate from the data, not from assumptions.

### 3. Check the spec against every trial's logs

Before rendering anything, compute the intervals between consecutive messages across the whole dataset and look at their distributions. Each one should cluster tightly around the refresh-locked duration from step 2, not the nominal one. Also check that each branch fires when the code says it should (for example, "the fallback window ran on every trial whose first window failed"). If an interval doesn't fit, find out why before you render.

Then list every disagreement between the code, the logs, the methods text and the figure. Report these to the user even though they didn't ask, because they matter for the paper. Typical ones:

- a rule, threshold or duration in the code that differs from the methods text
- screens the code shows that the figure and the methods leave out, or the reverse
- a stimulus drawn differently from its picture in the figure (line style, size, color)

Render what the code did, and say so.

### 4. Choose real trials

Replaying real trials keeps every on-screen number true: the signal trace, the baseline, the threshold, the decision, the response and the coded outcome. Write an extraction script with a `--list` mode that prints every candidate trial by condition, along with the values that decided it. Then choose:

- one clear example per condition, with the deciding value well past its threshold so the decision is obvious at a glance
- the edge cases you're showing, such as a recycled trial and its restart
- the same stimulus across conditions where possible, ideally the one in the figure, so the condition is the only thing that changes

Write the chosen trials to one JSON file. For each trial, include the CSV row (plus the previous row if state carries over, like running baselines or balancer counts), the messages from this trial's start to the next trial's start, and the raw signal over the same span. Show only the dataset's de-identified IDs.

### 5. Design the frame

These defaults worked for a 16:9 talk slide at 1920 × 1080 and 60 fps:

- **Left side.** The participant screen, drawn in task pixels and scaled uniformly (for example, a 1024 × 768 task screen at 0.78) with a thin frame, and the figure's labels and colored bars under it.
- **Right side.** A segment timeline for the trial with a playhead. Below it, the real signal against its thresholds, drawn only during the epochs the code actually sampled. Then a running log of messages and decisions that appear as they happen.
- **Bottom.** Cards for the CSV columns the trial ends up with (condition code, flags, response, accuracy). Each card fills in when the code would have written it.
- **Header.** The chapter, the trial ID and a task-time clock.
- **Cards.** A title card, then a short card before each chapter that says in two or three sentences what's about to happen and why.

Use the figure's hex colors and font, read from the figure code. Fonts the figure downloads at runtime (Google Fonts) need fetching once.

Keep on-screen prose short and about the task. Method notes ("each change sits at its logged EyeLink time") belong in the README and the talk, not on frames.

### 6. Draw the participant screen

Translate each PsychoPy stimulus to canvas calls using `references/psychopy-to-pixels.md`. Comment each draw call with the PsychoPy call it mirrors, so anyone can audit the match:

```python
# visual.Circle(radius=75, lineWidth=2, lineColor='black', opacity=0.3, fillColor=None)
c.drawCircle(cx, cy, 75, paint('black', 0.3, stroke=2))
```

Drive everything from one function, `screen_state(t)`, which returns the participant screen at task time t. Build it from the logged flip times, plus any sub-events the task didn't log (like the phases of a flicker), reconstructed from the code and the refresh rate and anchored to the nearest logged flip. The renderer, the stills and the checker all call this function, so they can't drift apart.

### 7. Render

Copy `scripts/video_kit.py` next to the project's render script. Pin the dependencies in a PEP 723 header (see `example_render.py`) and run with `uv run script.py`. That way `uv` builds an isolated environment and the project's `pyproject.toml` stays untouched. With pinned versions, re-rendering is byte-identical, which is a cheap reproducibility check.

Give the render script a few modes:

- `all [OUTDIR]` rebuilds every video in one command
- `video OUT SCENES [--speed X]` renders one cut
- `frames OUTDIR SCENE t1 t2 ...` writes PNG stills at task times

Look at stills of the hard moments before you encode anything long: the first cue frame, a blink, the probe, each card. Use the Read tool on the PNGs. Stills take seconds; a full set of videos takes minutes.

A good default set:

- one combined video: title, then a card and a trial for each condition
- the same video at 0.5×
- one short clip per condition, so the user can drop single conditions onto slides
- a close-up of the briefest stimulus (step 8)

For slowed versions, frame f shows task time `f / fps * speed`. The clock stays in task time. Every frame gets a corner badge (for example "0.5× SPEED"), and the title says the speed, so a slowed clip is never mistaken for real timing.

### 8. Close-up of brief or faint stimuli

If a key stimulus is brief or low-contrast (a flickering cue, a masked target, a faint ring), make a separate video so the audience can see what participants actually saw. These beats work well:

1. A title card.
2. One real-speed look at 1:1 pixels. Most people miss it, which is the point.
3. A replay that pauses on the first frame the stimulus is visible, with a "paused" badge.
4. The screen slides aside, an inset box marks the region, and a panel zooms it to an integer scale (3×). Callouts give the code's parameters (radius, line width, opacity as the resulting gray level on the background, visual angle at the viewing distance), and a strip shows each on and off phase in milliseconds.
5. The stimulus in the zoom at 0.25×, then twice at real speed.
6. Unzoom.
7. Three real-size, real-speed repeats on the 1:1 screen. The last one runs on into the next screen, so viewers see the cue in context.

Draw the 1:1 screen on integer pixel positions so thin lines stay crisp.

### 9. Verify the encoded videos

Check the files people will actually play, not the renderer's intent. Decode each MP4 (`video_kit.decode`) and classify the participant screen in every frame from a few pixel probes. For example, check a pixel on the ring, one inside the probe, and one inside a control shape. Collapse the frames into runs (`video_kit.runs`) and print each run's start next to the logged time. `example_render.py check` shows the pattern.

Expect every change within one video frame of its logged time (17 ms at 60 fps, 8 ms of task time at 0.5×). Each state starts on the first video frame at or after its true time, so a 106-ms CRT phase shows as alternating 100 and 117 ms at 60 fps. Say this when you report.

For the slowed combined video, check one chapter at its offset to confirm that the speed mapping holds there. Re-render into a scratch folder and compare checksums with the delivered files to confirm the saved code reproduces them.

### 10. Report back

Tell the user:

- each video with its length and what it shows
- the timing check result, as the largest deviation in ms
- the code and figure discrepancies from step 3
- caveats from the end of `references/psychopy-to-pixels.md`: physical size on a projector, CRT luminance and gamma, and 60-fps quantization
- the commands to rebuild everything

Write a README next to the scripts with the same content plus how to swap in other trials. Offer variants (other speeds, other example trials, single-condition clips at other speeds) instead of rendering them unasked.

## When to ask the user

Most choices have a sensible default, so make the call and state it. Ask only when the answer changes the result and can't be found in the code or data:

- The task code or logs are missing.
- `deg` units need a viewing distance or monitor width that isn't recorded anywhere.
- The user cares which participant's trials appear, or whether IDs may appear on screen at all.
