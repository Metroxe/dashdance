# Mac fixes log

Fixes found by playing Dashdance on a MacBook Pro (M4 Pro, macOS 26) with a Mayflash adapter in Wii U mode.
Each fix is its own commit on `christopher/mac-fixes`, so any subset can go upstream as a PR.

How the loop works: play, hit a problem, run `tools/mac/report.sh "what happened"`, log it under
Open issues with the report folder, fix it, rebuild with `tools/mac/rebuild.sh`, confirm in play,
then move it to Fixed with the commit.

## Open issues

| # | Found | What happens | Evidence | Notes |
|---|---|---|---|---|
| 1 | 2026-09-16 | Crash mid-match (SIGABRT from `ppc::fatal` inside recursive guest calls `f_80373078`/`f_8036F1F8`) | `~/Library/Logs/DiagnosticReports/Dashdance-2026-09-16-093630.ips` | Same class as Hero88go/melee-unlocked#5. No session log exists for it: logging was broken (fix 4). |

## Fixed

| # | What was wrong | Fix | Commit |
|---|---|---|---|
| 1 | GameCube adapter never read on this Mac: `ReadPipeTO` on the interrupt pipe returns `kIOReturnBadArgument`, so the reader thread gave up after 20 failures. | Fall back to blocking `ReadPipe` when timed reads are rejected; abort the pipe on close so the blocking read wakes. | see git log |
| 2 | No way to quit from full screen except the Dock. | Cmd+Q requests exit from the SDL event loop. | see git log |
| 3 | HUD showed any adapter rate below 900 Hz as "125 Hz" (the Mayflash overclocks to ~540 Hz). | Show the measured rate. | see git log |
| 4 | No session logs at all: the first `host::log` ran before `main_mac` set the log path, so the file opened relative to cwd (`/` from Finder), failed, and was never retried. Crashes left no trace. | Buffer lines until the path is set; one timestamped log per launch in `~/Library/Application Support/Dashdance/Logs/`, newest 50 kept, `latest.log` symlink. | see git log |

## Setup notes that are not code

- `install.sh` does not work as-is: its `--depth 1` clone lacks the upstream commit `bootstrap_port.py` checks, and `setup.sh` clones doldecomp/melee at HEAD instead of the pinned revision. Workaround: full clone, and `git -C deps/melee checkout 05a1394faea2aac458e4bdd030621d8a5631ae62`.
- 1000 Hz polling without a driver (the README claim) did not work here: `SetPipePolicy` is rejected, and with no driver Apple's HID driver owns the adapter exclusively. The legacy GCAdapterDriver.kext (Permissive Security, SIP off) gives ~540 Hz, which looks like the Mayflash hardware cap.
