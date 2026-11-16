---
name: product-launch-video
description: "Create and revise product-launch demo videos from an app repository using real UI, synthetic data, animated walkthroughs, and crisp exports. Use for prototype-first launch videos, visual or soundtrack variants, and accompanying social launch copy when requested."
---

# Product Launch Video

Create an actual playable product demo that lets the user evaluate the creative direction. Keep the workflow portable across repositories, brands, and available rendering tools.

## Choose the requested scope

| Request | Work to perform |
| --- | --- |
| Initial demo or quick preview | Inspect the product, prepare sample data, and deliver a short rendered prototype |
| Visual, pacing, resolution, or mobile revision | Reuse the established story and capture pipeline; save a separately named version |
| New background track | Reuse the selected video master; edit and replace the music without re-encoding the picture when possible |
| Launch copy | Write platform-specific Markdown files tied to the finished demo and verified product facts |
| Posting times | Add audience-specific starting windows and a practical near-term schedule supported by current sources |

Perform the requested stage. If the user asks to review a prototype before investing in a longer video, deliver that prototype and wait for creative feedback before expanding it. Once a revision is authorized, complete it without adding another approval round. Preparing assets does not authorize publishing them.

## Establish the brief

Infer what the repository and existing conversation already establish:

- Product name, core benefit, intended viewer, and the action viewers should take.
- Repository, local startup command, demo routes, component library, branding, and useful existing fixtures.
- Primary web URL; optional mobile site and verified store links.
- Requested duration, aspect ratio, resolution, pace, palette, and soundtrack.
- Which earlier version to revise and which versions must remain available.

Ask only about missing choices that materially change the result. Continue independent work while optional preferences are pending. Make unresolved assumptions explicit. Treat a named color, song, duration, or app platform as a project choice rather than a default for future products.

## Starter prompt for another product

Replace the bracketed fields, omit optional lines, and paste this into the new repository's conversation:

```text
Use $product-launch-video for [PRODUCT NAME] in this repository.

Audience: [WHO SHOULD USE IT].
Core benefit: [THE JOB IT HELPS THEM DO].
Primary destination: [WEB APP URL].
Brand/reference site: [URL, IF AVAILABLE].
Mobile app: [STORE URL OR OMIT].

Make a polished product-launch demo showing a believable user completing
one useful workflow in the real app. Use realistic fictional sample data,
animated cursor interactions, purposeful camera movement, and readable UI.
Choose the strongest workflow from the repo if I haven't specified one.

Start with a 20–30 second prototype so I can review the direction before
we invest in a longer video. Use [VISUAL DIRECTION OR EXISTING BRAND],
with [CALM / ENERGETIC] pacing and enough time to understand each action.

Deliver a playable MP4, a local preview page, a poster/contact sheet,
and the scripts/settings needed to reproduce it. Make the UI crisp at
1080p; include a native 4K master if appropriate for the requested quality.
End with the product name and primary URL. Preserve each delivered version.

Optional music: [LOCAL AUDIO PATH].
Primary posting destination: [X / LINKEDIN / YOUTUBE / OTHER].
Stop after the reviewable prototype and tell me where to watch it.
```

## Build the demo

### 1. Inspect and isolate

Read applicable repository instructions, inspect the actual UI and feature behavior, and locate installed browser/rendering/encoding tools. Prefer the project's existing stack. Browser automation plus an HTML/canvas compositor and FFmpeg is a useful option; an established Remotion or other renderer is equally valid. Resolve executables and dependencies from the current environment or configurable paths; never depend on another project's personal filesystem paths.

Use the app's real components with a demo fixture or isolated local instance. Seed coherent fictional names, tasks, dates, messages, or metrics that explain the chosen workflow. Fix the clock when relative dates would make the capture inconsistent.

If authentication or hosted services prevent a local demo, use an existing demo mode or a disposable copy with mocked services. Keep demo-only changes out of the production app. Use dummy credentials and restrict demo requests to the necessary local or explicitly allowed endpoints; prevent fixture actions from reaching production data, email, payments, or analytics. Serve needed assets locally when network access is blocked.

### 2. Tell one short story

Show a concrete benefit through a few connected actions. A useful starting sequence is:

| Beat | Purpose | Example allocation for a 30-second cut |
| --- | --- | --- |
| Hook | Express the viewer's problem or desired outcome | 0–3 seconds |
| Orientation | Establish the real product and the relevant UI | 3–6 seconds |
| Interaction | Show two or three actions with visible results | 6–21 seconds |
| Supporting capability | Show mobile or another relevant benefit, if requested | 21–26 seconds |
| Close | Product name and a readable destination | 26–30 seconds |

Adapt these timings to the product. Omit optional scenes when they weaken the story. Give viewers time to read the input and understand the result. Use restrained zooms, pans, cursor arcs, and click feedback to direct attention. Add concise on-screen text so the key benefit and actions remain understandable with sound off. Let the actual workflow carry the demo; keep claims consistent with working features.

### 3. Capture real interactions at sufficient resolution

Drive real UI actions and verify their outcomes: submitted content appears, moved items arrive, statuses change, and navigation reaches the intended screen. Capture stable states or a high-quality continuous recording according to the interaction. For state-based animation, capture enough intermediate typing and drag states to keep motion smooth.

Wait for fonts and images before capturing. Remove capture-only debug overlays and duplicate cursors while preserving meaningful focus, hover, and interaction states.

Budget source pixels for the closest zoom: the sampled region's CSS width multiplied by capture device scale must cover its maximum displayed width in output pixels; check height too. A 4K output label does not restore missing detail in a small screenshot. Recapture when necessary, and keep text and vector graphics native to the output resolution.

Record source dimensions, capture scale, relevant element bounds, action results, and browser errors in a capture manifest. These make camera alignment and later revisions reproducible.

### 4. Compose and review before the expensive render

Use a deterministic timeline, such as `renderFrame(timeInSeconds)`, with explicit scene durations, camera transforms, cursor paths, and transitions. Keep output frame rate separate from story timing. To slow a revision, adjust the timeline and hold times while retaining smooth motion; retime audio cues deliberately.

Render representative frames and a contact sheet first. Inspect typography, cropped edges, cursor alignment, safe margins, and the final URL at the intended viewing size. In the final pass, bound decoded-image caches, release unused image resources, and respect encoder backpressure so high-resolution captures do not exhaust memory.

### 5. Add mobile only when relevant

Use the supplied official site and store listing to obtain the correct link and permitted product screenshots. Verify that the link matches the product. Device frames can present those screens effectively; describe them in production notes as screenshots unless genuine mobile interactions were recorded.

Keep the primary web URL readable on the closing card. If using a store QR code, verify it decodes from the compressed posting export at viewing size. Put clickable web and store links in the review page and requested launch copy.

### 6. Export and verify

Choose delivery settings for the requested destination and verify current platform requirements when claiming compatibility. Useful starting exports for a landscape demo are:

- **Master:** native 3840 × 2160 when HD refinement is requested, at 30 or 60 fps appropriate to the captured motion.
- **Posting copy:** 1920 × 1080 at 30 fps, downsampled from the master when available.
- **Encoding:** H.264, yuv420p, consistent BT.709 color handling, AAC stereo, and fast-start MP4. Use a high-quality encode, then inspect actual size and playback. These are defaults, not universal platform limits.

For vertical delivery, reframe the composition so UI and text remain readable. A short landscape file does not automatically become a YouTube Short.

Verify duration, dimensions, frame rate, decodable audio, and representative beginning/middle/end frames. Play the result when tools permit; check text at the posting size and confirm meaningful UI outcomes. Report only the checks actually performed.

Deliver clearly named files, a lightweight preview page with working source/download selectors, a poster/contact sheet, and regeneration instructions. Capture logs, source attribution, and edit settings belong alongside the artifacts. Keep large intermediate files out of commits unless requested.

## Revise without losing earlier work

Create explicit versions such as `launch-v1`, `launch-v2`, or `launch-v2-neutral`. Preserve previously delivered MP4s and their source settings. Record checksums before operations that could replace them.

Apply feedback to the affected layer:

- **Too fast:** extend scene timing and reading holds; update chapter cues and sound timing.
- **Wrong palette:** revise graphic treatments and supported demo theme controls; retain an authentic representation of the product.
- **Blurry:** inspect the source capture and scaling chain, then recapture or render natively as needed.
- **Add mobile:** add a short supporting scene and revise the ending/timeline deliberately.
- **New music:** use the audio-only path below.

The preview can default to the newest requested variant while keeping older versions selectable. Name soundtrack options after their tracks so multiple alternatives remain distinguishable.

## Audio-only variant

1. Locate the chosen picture master and supplied audio. Inspect the audio's duration, channels, opening silence, and peak levels. Choose an excerpt that fits; state the selected offset and duration. The beginning is a reasonable default when no cue is specified.
2. Match the picture duration, add suitable fades, and set gain from the measured source. A short fade-in and roughly 1–2 seconds of fade-out often fit a 30-second demo, but adapt to the music and ending. Avoid clipping; do not force every source to the same gain reduction.
3. Check whether the existing mix contains narration or useful effects. Preserve separate narration/effect stems when applicable. Replacing a mixed audio stream also removes those sounds, so handle that choice explicitly when it matters.
4. Encode compatible audio and mux it into a new filename using video stream copy. For FFmpeg, select the existing picture with `-map 0:v:0`, the replacement audio with `-map 1:a:0`, and `-c:v copy`. Bound the final duration and retain fast-start playback. Avoid shortening the picture accidentally when music is shorter; choose or prepare an adequate excerpt first.
5. Create the requested master/posting variants, preserve earlier soundtracks and manifests, and save the source path, excerpt, gain, fades, and codec settings in a new edit record.
6. Decode/check the new audio, compare video-stream hashes with the source, and confirm earlier deliverables remain unchanged. Update the review selector and verify its download targets.

## Optional launch copy and posting schedule

When requested, write separate `x.md`, `linkedin.md`, and `youtube.md` files containing ready-to-paste copy. Include a clear recommended version, a small number of distinct alternatives, a direct product link, and the relevant mobile link. Tailor the voice and structure to each platform. For YouTube include title, description, pinned comment, and useful thumbnail direction.

Verify product claims against the app and official sources. Resolve material pricing discrepancies or omit the disputed claim while continuing useful work. Use real evidence for traction and results. Match the copy to what the demo actually shows.

Verify current character limits and URL counting, YouTube format/link behavior, and other relevant platform constraints. Keep citations and publishing notes outside the text intended for posting.

For timing, establish audience geography and the user's time zone. Research current first-party platform guidance or studies with disclosed methods. Distinguish engagement findings from conversion evidence, and label inferred recommendations. Use a nearby practical launch opportunity; a generic weekday peak does not justify postponing a ready launch. Check the current date, day of week, and daylight saving conversions before writing a dated schedule. Keep all platform files consistent when it changes.

Measure attributed visits, signups, and a product-specific first successful action using comparable observation windows. Verify that attribution works before claiming a post generated those users. Treat timing and hook tests as separate experiments. No posting hour or copy formula guarantees virality.

## Follow-up prompts

Use these independently after a preview exists:

```text
Make version 2 about 20% slower, especially during [ACTION].
Try [PALETTE / STYLE] and make the UI genuinely crisp at 4K.
Preserve version 1 and give me a comparison player plus a 1080p posting copy.
```

```text
Add a short mobile-app moment using [OFFICIAL WEBSITE / STORE URL].
Keep [WEB APP URL] visible in the closing card and include both clickable
links in the review page. Save this as another version.
```

```text
Make a separate version of [EXISTING VIDEO] with [LOCAL AUDIO PATH]
as the background music. Keep the picture quality unchanged, fit the music
to the existing duration with gentle fades, and preserve prior soundtracks.
```

```text
Write X, LinkedIn, and YouTube launch copy for the approved demo in separate
Markdown files. Include recommended copy, a few alternate hooks, and direct
product links. Suggest near-term posting windows for [AUDIENCE REGION]
in [TIME ZONE], explain the evidence, and include a conversion test plan.
Do not publish anything.
```

## Completion

Link the requested artifacts and identify the version, duration, resolution, and chosen soundtrack where relevant. Summarize meaningful validation and any remaining limitation. A prototype request is complete when its reviewable preview is delivered; a soundtrack request is complete when the new playable variant is delivered. Do not expand either into an unrelated full launch campaign.
