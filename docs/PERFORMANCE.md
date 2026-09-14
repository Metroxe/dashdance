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

## GPU experiments (M5 Pro, full screen 3024×1898, Onett, 60 s of play)

| Setting | GPU per frame | XFB-to-panel latency |
|---|---|---|
| 1× internal (640×528) | 1.8 ms | 4.1 ms |
| 2× internal (1280×1056) | 2.6 ms | 4.6 ms |
| 4× internal (2560×2112), precise shader math | 6.2 ms | 11.4 ms |
| 4×, anisotropic filtering off | 6.2 ms | (no change: anisotropy is free) |
| 4×, shader fast math | 4.6 ms | 6.7 ms |

GPU cost scales with pixels: the TEV pixel shaders are ALU-bound (they emulate the GameCube's 8-bit
integer combiners exactly, so half precision is not an option). Fast math changes only the float
texture-coordinate and fog paths and produced pixel-identical captures on deterministic boot frames, so
it is on by default (`MELEE_METAL_FASTMATH=0` turns it off). The competitive preset picks 2×: the
lowest latency that still looks crisp on a laptop panel. Latency follows GPU time almost one to one
in full screen, so internal resolution is the single biggest latency knob a player has.

Simulation side: the GX vertex decoder builds a per-draw plan (formats, fixed-point scales, array
bases) once and writes vertices in place; its output is byte-identical to the previous decoder.

## Simulation-thread work (M5 Pro, Onett, 12 s `sample` of the game thread)

| Change | Effect |
|---|---|
| Vertex decoder builds a per-draw plan once (formats, scales, array bases) instead of re-deriving them per component | decode time roughly halved; output byte-identical |
| FIFO parser keeps a read cursor and the pending command's length, and caches the vertex descriptor per CP state | the game streams vertices 4 bytes at a time and the parser used to rebuild the descriptor for every write; parser samples down 40% |
| Texture bytes compared once per texture per frame instead of on every draw | the per-draw `memcmp` left the profile entirely |
| Input events pumped after the frame sleep, right before the VI interrupt | keyboard and Bluetooth-pad presses used to wait up to a frame's slack (about 12 ms) before the game read them; now they are sampled at the last moment |
| Audio: 256-frame CoreAudio buffer plus a 20 ms ring | 26 ms of queued audio, down from about 30; 12 ms starved several times a second and was rejected |

All of it was checked against deterministic boot captures (pixel-identical) and 60 s matches (zero
late frames).

Negative result: `-mcpu=apple-m1` plus ThinLTO for the whole binary produced no gain above run-to-run
noise on a 4000-frame unpaced boot or a 60 s match, and a 27% larger executable. The build stays
plain `-O3`. The translated game is dominated by loads and stores through the guest-memory helpers,
which are already inlined; there is no cross-module inlining left for LTO to find.
