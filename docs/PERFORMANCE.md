# Performance and latency: how it is measured

All numbers in the README come from the game's own instrumentation, run on an Apple M5 Pro MacBook Pro
(120 Hz ProMotion display) with nothing else building and no Simulators booted.

## Signals in the log

- `[frame N] gx: ... | sim: X ms/frame (worst Y) | disc .. ax .. render .. texture .. | render thread: ...`
  every 60 frames. `sim` is the simulation thread's work per frame with sleep excluded; the slots
  after it attribute that time (disc reads, audio, EXI/Slippi, texture snapshots, render encoding,
  texture uploads, event pump, GPU wait, drawable wait). Costs from the render thread are listed
  separately.
- `sim frame N took X ms (ms: ...)` for any frame over one 60 Hz period (16.7 ms). Zero of these
  during play is the target.
- `[latency] xfb-copy -> panel A ms avg (worst B), commit -> panel C ms | gpu D ms avg (worst E), queue F ms`
  with `MELEE_METAL_LATENCY=1`: the time from the game finishing a frame (its XFB copy) to the
  pixels on the panel, from Metal's presented timestamps, plus GPU execution time.
- `renderer: display stalled; drained a backlog of N frames` when the display held the drawables and
  the render thread skipped presenting to catch up (the simulation did not wait).
- `metal: N pipelines compiled in the background` and `metal: compiling N pipelines from the previous
  session` for the shader pipeline cache (`<cache>/pipelines.bin`).

## Scripted matches

`MELEE_PAD_FILE` drives both pads from a text file, so a shell script can boot to a VS match, pick a
stage, play for a minute with stay-alive inputs and grep the log. A calibrated stage select from the
cursor's start position (bottom-left, below the grid): up 0.15 s = Onett, up-right 0.15 s = Final
Destination, up-right 0.3 s = Pokémon Stadium, up-right 0.55 s = Flat Zone, right+down 2 s = Corneria,
up-left 2 s = Icicle Mountain, up-left 0.3 s = Random. Pressing A picks the last highlighted stage.

## What was found and fixed (September 2026)

| Symptom | Cause | Fix |
|---|---|---|
| 16–83 late frames a minute, in bursts | `nextDrawable` blocked 15–30 ms when the display pipeline held both drawables; the renderer ran on the simulation thread | Render thread with a frame queue; backlogs execute without presenting |
| 200–800 ms freeze on a first visit to a stage | 28 shaders compiled inline on the render path | Background pipeline compilation with the draw skipped while pending; pipeline list persisted and precompiled at launch |
| 25 ms XFB-to-panel in a window | One compositor frame | Full screen by default (10 ms); opaque layer for direct-to-display |
| Occasional 20–30 ms frames under load | Scheduler | Mach time-constraint (real-time) policy on the simulation thread |

Results after the fixes: seven stages, 60 s of play each, zero late frames on six (worst frame
7–10 ms); Flat Zone still shows a few, under investigation.
