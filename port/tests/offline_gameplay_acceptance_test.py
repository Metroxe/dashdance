#!/usr/bin/env python3
"""Pure fixtures for tools/check_offline_gameplay.py; this never runs the game."""

from __future__ import annotations

from pathlib import Path
import copy
import hashlib
import importlib.util
import json
import shutil
import struct
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "check_offline_gameplay.py"
SPEC = importlib.util.spec_from_file_location("check_offline_gameplay", MODULE_PATH)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECKER
SPEC.loader.exec_module(CHECKER)

FIXTURE_SLIPPI_CSS_BYTES = bytes(range(256)) * 16
FIXTURE_SYS_CONTENTS = {
    CHECKER.SLIPPI_CSS_SYS_PATH: FIXTURE_SLIPPI_CSS_BYTES,
    "codehandler.bin": b"fixture codehandler",
    "bootloader.gct": b"fixture bootloader",
    "GameSettings/GALE01r2.ini": b"[Core]\nfixture = true\n",
}
FIXTURE_SYS_SHA256 = {
    name: hashlib.sha256(content).hexdigest()
    for name, content in FIXTURE_SYS_CONTENTS.items()
}
FIXTURE_SLIPPI_CSS_SHA256 = FIXTURE_SYS_SHA256[CHECKER.SLIPPI_CSS_SYS_PATH]


def event(command: int, payload: bytes) -> bytes:
    return bytes((command,)) + payload


def replay_bytes(
    *,
    positive_frame: int = 1,
    game_end: bool = False,
    mismatched_positive: bool = False,
    bookend_before_post: bool = False,
    game_end_before_last_frame: bool = False,
) -> bytes:
    sizes = {
        CHECKER.CMD_GAME_START: 4,
        CHECKER.CMD_PRE_FRAME: 8,
        CHECKER.CMD_POST_FRAME: 8,
        CHECKER.CMD_GAME_END: 1,
        CHECKER.CMD_FRAME_BOOKEND: 4,
    }
    table = bytearray((1 + 3 * len(sizes),))
    for command, size in sizes.items():
        table.extend((command, size >> 8, size & 0xFF))
    raw = bytearray(event(CHECKER.CMD_COMMANDS, bytes(table)))
    raw += event(CHECKER.CMD_GAME_START, b"GAME")
    end_written = False
    for frame in (-123, positive_frame):
        pre_encoded = struct.pack(">i", frame)
        post_frame = frame + 1 if mismatched_positive and frame == positive_frame else frame
        bookend_frame = frame + 2 if mismatched_positive and frame == positive_frame else frame
        post_encoded = struct.pack(">i", post_frame)
        bookend_encoded = struct.pack(">i", bookend_frame)
        raw += event(CHECKER.CMD_PRE_FRAME, pre_encoded + b"PRE!")
        if game_end and game_end_before_last_frame and frame == positive_frame:
            raw += event(CHECKER.CMD_GAME_END, b"\x02")
            end_written = True
        if bookend_before_post:
            raw += event(CHECKER.CMD_FRAME_BOOKEND, bookend_encoded)
        raw += event(CHECKER.CMD_POST_FRAME, post_encoded + b"POST")
        if not bookend_before_post:
            raw += event(CHECKER.CMD_FRAME_BOOKEND, bookend_encoded)
    if game_end and not end_written:
        raw += event(CHECKER.CMD_GAME_END, b"\x02")
    return b"{U\x03raw[$U#l" + struct.pack(">I", len(raw)) + bytes(raw) + b"{}"


def log_text(
    *,
    results: bool = False,
    online_game_scene: bool = False,
    inconsistent_combined: bool = False,
) -> str:
    scenes = [
        (1, 0x28, 0x00),
        (80, 0x18, 0x00),
        (200, 0x00, 0x00),
        (260, 0x01, 0x00),
        (500, 0x02, 0x00),
        (700, 0x02, 0x01),
        (900, 0x02, 0x08 if online_game_scene else 0x02),
    ]
    if results:
        scenes.append((1200, 0x02, 0x04))
    telemetry_lines = []
    for retrace, mode_byte, state_byte in scenes:
        combined = (state_byte << 8) | mode_byte
        if inconsistent_combined and retrace == scenes[-1][0]:
            combined ^= 1
        telemetry_lines.append(
            f"accept: scene retrace={retrace} mode_byte=0x{mode_byte:02X} "
            f"state_byte=0x{state_byte:02X} combined=0x{combined:04X}"
        )
    telemetry = "\n".join(telemetry_lines)
    return (
        "Melee Unlocked fixture: offline headless AOT gate\n"
        "execution: strict_aot=true, frames=1400\n"
        "slippi: game loads the GCT (58256 bytes) at 8065CC80\n"
        f"{telemetry}\n"
        "[aot] strict=yes missing-target attempts=0 interpreted calls=0 instructions=0\n"
        "headless result: exit=0 retraces=1400 requested=1400\n"
    )


def digest(path: Path, algorithm: str = "sha256") -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def loaded_module_record(
    *,
    name: str = "SlippiCSS.dat",
    address: int = 0x80400000,
    byte_count: int = 4096,
    sha256: str = FIXTURE_SLIPPI_CSS_SHA256,
    sha256_valid: bool = True,
    loads: int = 1,
    first_event: int = 1,
    last_event: int = 1,
    name_truncated: bool = False,
) -> dict[str, object]:
    return {
        "name": name,
        "address": address,
        "bytes": byte_count,
        "sha256": sha256,
        "sha256_valid": sha256_valid,
        "loads": loads,
        "first_event": first_event,
        "last_event": last_event,
        "name_truncated": name_truncated,
    }


def write_run_evidence(log: Path, replay: Path) -> None:
    cache = log.parent.resolve()
    executable = (cache.parent / "melee_port_headless").resolve()
    input_manifest = (cache.parent / "port-inputs.json").resolve()
    sys_dir = (cache.parent / "SlippiSys").resolve()
    if sys_dir.exists():
        shutil.rmtree(sys_dir)
    for name, content in FIXTURE_SYS_CONTENTS.items():
        path = sys_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    executable.write_bytes(b"fixture executable")
    input_manifest.write_text(
        json.dumps(
            {
                "fixture": True,
                "slippi_sys_dir": str(sys_dir),
                "slippi_sys_files_sha256": FIXTURE_SYS_SHA256,
            }
        )
        + "\n",
        encoding="utf-8",
    )
    executable_hash = digest(executable)
    manifest_hash = digest(input_manifest)
    script = CHECKER.ACCEPTANCE_SCRIPT.resolve(strict=True)
    replay_summary = CHECKER.parse_replay(replay)
    base = {
        "schema": "melee-native-headless-run-v1",
        "phase": "prepared",
        "command": [str(executable), "--offline", "--script", str(script)],
        "executable": {"path": str(executable), "sha256": executable_hash},
        "input_manifest": {
            "path": str(input_manifest),
            "compiled_sha256": manifest_hash,
            "actual_sha256": manifest_hash,
        },
        "inputs": {
            "dol_expected_sha1": "fixture-dol",
            "script": {"path": str(script), "sha1": digest(script, "sha1")},
            "slippi_sys_tree_verified": True,
            "slippi_sys_files_sha256": FIXTURE_SYS_SHA256,
            "slippi": {
                name: {
                    "path": str(sys_dir / name),
                    "verified": True,
                    "sha256": FIXTURE_SYS_SHA256[name],
                    "build_sha256": FIXTURE_SYS_SHA256[name],
                }
                for name in sorted(CHECKER.REQUIRED_SLIPPI_INPUTS)
            },
        },
        "upstream_pin": {},
        "decomp_pin": {},
        "gct_base": CHECKER.GCT_ADDRESS,
        "bounds": {"frames": 1400, "time_base": 0, "hang_watch_seconds": 10},
        "acceptance": {"expect_scene": True, "expected_combined": 0x0202},
        "capabilities": {
            "offline": True,
            "strict_aot": True,
            "gpu_presentation": False,
            "device_audio": False,
        },
        "fp_profile": "fixture",
        "isolation": {
            "profile_dir": str(cache.parent / "profile"),
            "card_dir": str(cache.parent / "card"),
            "cache_dir": str(cache),
            "replay_dir": str((cache / "replays").resolve()),
        },
        "outputs": {"log": str(log.resolve()), "state_trace": "", "audio_dump": ""},
    }
    result = copy.deepcopy(base)
    result["phase"] = "finished"
    result["inputs"]["dol_actual_sha1"] = "fixture-dol"
    result["inputs"]["dol_verified"] = True
    result["acceptance"]["scene_observed"] = True
    result["exit"] = {
        "code": 0,
        "cause": "frame_bound",
        "detail": "",
        "orderly_shutdown": True,
    }
    result["counters"] = {
        "retraces": 1400,
        "aot": {
            "strict": True,
            "missing_attempts": 0,
            "interpreted_calls": 0,
            "interpreted_instructions": 0,
            "unrecorded_attempts": 0,
            "unrecorded_pc_visits": 0,
            "unrecorded_modules": 0,
            "loaded_module_records": 1,
            "modules": [loaded_module_record()],
        },
        "slippi": {"gct_load_address": CHECKER.GCT_ADDRESS, "replays_written": 1},
    }
    frame_bounds = [
        value
        for value in (
            replay_summary.min_pre_frame,
            replay_summary.max_pre_frame,
            replay_summary.min_post_frame,
            replay_summary.max_post_frame,
        )
        if value is not None
    ]
    result["recording"] = {
        "commands": replay_summary.count(CHECKER.CMD_COMMANDS),
        "game_start": replay_summary.count(CHECKER.CMD_GAME_START),
        "pre_frame": replay_summary.count(CHECKER.CMD_PRE_FRAME),
        "post_frame": replay_summary.count(CHECKER.CMD_POST_FRAME),
        "game_end": replay_summary.count(CHECKER.CMD_GAME_END),
        "has_frames": bool(frame_bounds),
        "min_frame": min(frame_bounds) if frame_bounds else 0,
        "max_frame": max(frame_bounds) if frame_bounds else 0,
        "match_input_started": replay_summary.max_post_frame is not None
        and replay_summary.max_post_frame >= 1,
    }
    scene_rows = [
        {
            "retrace": int(match.group(1)),
            "mode_byte": int(match.group(2), 16),
            "state_byte": int(match.group(3), 16),
            "combined": int(match.group(4), 16),
        }
        for match in CHECKER.SCENE_RE.finditer(log.read_text(encoding="utf-8"))
    ]
    result["scenes"] = {
        "mode_address": CHECKER.SCENE_MODE_ADDRESS,
        "state_address": CHECKER.SCENE_STATE_ADDRESS,
        "encoding": "0xSSMM: state byte high, mode byte low",
        "transitions": len(scene_rows),
        "unrecorded": 0,
        "timeline": scene_rows,
    }
    result["artifacts"] = {
        "log": {
            "path": str(log.resolve()),
            "bytes": log.stat().st_size,
            "sha256": digest(log),
            "closed": True,
        },
        "replay": {
            "path": str(replay.resolve()),
            "bytes": replay.stat().st_size,
            "sha256": digest(replay),
            "closed": True,
        },
        "replay_status": "closed",
    }
    (cache / "launch.json").write_text(json.dumps(base), encoding="utf-8")
    (cache / "result.json").write_text(json.dumps(result), encoding="utf-8")
    sidecar = {
        "verified": True,
        "binary": str(executable),
        "binary_sha256": executable_hash,
        "input_manifest": str(input_manifest),
        "input_manifest_sha256": manifest_hash,
    }
    executable.with_name(executable.name + ".verified.json").write_text(
        json.dumps(sidecar), encoding="utf-8"
    )


def expect_failure(log: Path, replay: Path, fragment: str, *, prepare: bool = True, **kwargs) -> None:
    if prepare:
        write_run_evidence(log, replay)
    try:
        CHECKER.check_acceptance(log, replay, **kwargs)
    except CHECKER.AcceptanceFailure as error:
        assert fragment in str(error), (fragment, str(error))
    else:
        raise AssertionError(f"expected failure containing {fragment!r}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="offline-gameplay-check-") as temporary:
        directory = Path(temporary)
        cache = directory / "cache"
        replay_directory = cache / "replays"
        replay_directory.mkdir(parents=True)
        log = cache / "melee_port.log"
        replay = replay_directory / "game.slp"

        log.write_text(log_text(), encoding="utf-8")
        replay.write_bytes(replay_bytes())
        write_run_evidence(log, replay)
        report = CHECKER.check_acceptance(log, replay)
        assert report.reached == ("boot", "main-menu", "vs-css", "sss", "in-game")
        assert report.replay.max_pre_frame == 1
        assert report.replay.max_post_frame == 1
        assert report.replay.count(CHECKER.CMD_FRAME_BOOKEND) == 2

        log.write_text(log_text(results=True), encoding="utf-8")
        replay.write_bytes(replay_bytes(game_end=True))
        write_run_evidence(log, replay)
        report = CHECKER.check_acceptance(log, replay, through="results")
        assert report.reached[-1] == "results"
        assert report.replay.count(CHECKER.CMD_GAME_END) == 1

        replay.write_bytes(replay_bytes())
        expect_failure(log, replay, "game-end event", through="results")

        log.write_text(log_text(online_game_scene=True), encoding="utf-8")
        replay.write_bytes(replay_bytes())
        expect_failure(log, replay, "expected offline scene 0x0202")

        log.write_text(log_text(inconsistent_combined=True), encoding="utf-8")
        expect_failure(log, replay, "packed value disagrees")

        log.write_text(
            "execution: strict_aot=true\n"
            "slippi: game loads the GCT (58256 bytes) at 8065CC80\n"
            "[frame 2400] gx: 15385349 cmds\n"
            "[aot] strict=yes missing-target attempts=0 interpreted calls=0 instructions=0\n"
            "headless result: exit=0 retraces=2400 requested=2400\n",
            encoding="utf-8",
        )
        expect_failure(log, replay, "no scene-byte telemetry")

        log.write_text(log_text(), encoding="utf-8")
        replay.write_bytes(replay_bytes(positive_frame=0))
        expect_failure(log, replay, "no ordered same-frame")

        replay.write_bytes(replay_bytes(mismatched_positive=True))
        expect_failure(log, replay, "no ordered same-frame")

        replay.write_bytes(replay_bytes(bookend_before_post=True))
        expect_failure(log, replay, "no ordered same-frame")

        log.write_text(log_text(results=True), encoding="utf-8")
        replay.write_bytes(replay_bytes(game_end=True, game_end_before_last_frame=True))
        expect_failure(log, replay, "does not follow all frame data", through="results")

        replay.write_bytes(replay_bytes())
        log.write_text(log_text(), encoding="utf-8")
        write_run_evidence(log, replay)
        result_path = cache / "result.json"
        result = json.loads(result_path.read_text(encoding="utf-8"))
        result["outputs"]["log"] = str(cache / "unrelated.log")
        result_path.write_text(json.dumps(result), encoding="utf-8")
        expect_failure(log, replay, "immutable field outputs", prepare=False)

        log.write_text(log_text(), encoding="utf-8")
        replay.write_bytes(replay_bytes())
        write_run_evidence(log, replay)
        log.write_text(log.read_text(encoding="utf-8") + "tampered\n", encoding="utf-8")
        expect_failure(log, replay, "bind the supplied log", prepare=False)

        log.write_text(log_text(), encoding="utf-8")
        replay.write_bytes(replay_bytes())
        write_run_evidence(log, replay)
        replay.write_bytes(replay.read_bytes() + b"tampered")
        expect_failure(log, replay, "bind the supplied replay", prepare=False)

        log.write_text(log_text(), encoding="utf-8")
        replay.write_bytes(replay_bytes())
        write_run_evidence(log, replay)
        for evidence_path in (cache / "launch.json", result_path):
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            del evidence["inputs"]["slippi"]["bootloader.gct"]
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        expect_failure(
            log,
            replay,
            "runtime Slippi inputs were not verified",
            prepare=False,
        )

        write_run_evidence(log, replay)
        for evidence_path in (cache / "launch.json", result_path):
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            evidence["inputs"]["slippi_sys_files_sha256"]["unexpected.dat"] = "c3" * 32
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        expect_failure(
            log,
            replay,
            "build and runtime Slippi Sys inventories disagree",
            prepare=False,
        )

        write_run_evidence(log, replay)
        slippi_css = cache.parent / "SlippiSys" / CHECKER.SLIPPI_CSS_SYS_PATH
        slippi_css.write_bytes(b"X" * len(FIXTURE_SLIPPI_CSS_BYTES))
        expect_failure(
            log,
            replay,
            "current Slippi Sys inventory or contents",
            prepare=False,
        )

        write_run_evidence(log, replay)
        slippi_css.unlink()
        symlink_target = slippi_css.with_suffix(".target")
        symlink_target.write_bytes(FIXTURE_SLIPPI_CSS_BYTES)
        slippi_css.symlink_to(symlink_target.name)
        expect_failure(
            log,
            replay,
            "current immutable Slippi Sys tree must not contain symlinks",
            prepare=False,
        )

        def write_module_evidence(
            modules: list[dict[str, object]],
            *,
            total: int,
            unrecorded: int = 0,
        ) -> None:
            write_run_evidence(log, replay)
            current = json.loads(result_path.read_text(encoding="utf-8"))
            current["counters"]["aot"]["loaded_module_records"] = total
            current["counters"]["aot"]["unrecorded_modules"] = unrecorded
            current["counters"]["aot"]["modules"] = modules
            result_path.write_text(json.dumps(current), encoding="utf-8")

        def expect_module_failure(
            modules: list[dict[str, object]],
            *,
            total: int,
            fragment: str,
            unrecorded: int = 0,
        ) -> None:
            write_module_evidence(modules, total=total, unrecorded=unrecorded)
            expect_failure(log, replay, fragment, prepare=False)

        write_module_evidence(
            [loaded_module_record(loads=129, first_event=1, last_event=129)],
            total=129,
        )
        CHECKER.check_acceptance(log, replay)

        valid_name_boundary = [
            loaded_module_record(),
            loaded_module_record(
                name="x" * CHECKER.MAX_LOADED_MODULE_NAME_BYTES,
                address=0x80401000,
                first_event=2,
                last_event=2,
            ),
        ]
        write_module_evidence(valid_name_boundary, total=2)
        CHECKER.check_acceptance(log, replay)

        expect_module_failure(
            [], total=0, fragment="1..128 retained loaded-module identities"
        )
        expect_module_failure(
            [loaded_module_record()],
            total=2,
            unrecorded=1,
            fragment="unrecorded_modules=0",
        )
        expect_module_failure(
            [loaded_module_record()],
            total=2,
            fragment="load-event accounting",
        )

        too_many_modules = [
            loaded_module_record(
                name="SlippiCSS.dat" if index == 0 else f"Module{index}.dat",
                address=0x80400000 + index * 0x1000,
                first_event=index + 1,
                last_event=index + 1,
            )
            for index in range(CHECKER.MAX_LOADED_MODULES + 1)
        ]
        expect_module_failure(
            too_many_modules,
            total=CHECKER.MAX_LOADED_MODULES + 1,
            fragment="1..128 retained loaded-module identities",
        )

        expect_module_failure(
            [loaded_module_record(name="")],
            total=1,
            fragment="invalid bounded name",
        )
        expect_module_failure(
            [loaded_module_record(name="é" * 48)],
            total=1,
            fragment="invalid bounded name",
        )
        expect_module_failure(
            [loaded_module_record(name_truncated=True)],
            total=1,
            fragment="untruncated name",
        )
        missing_name_truncation = loaded_module_record()
        del missing_name_truncation["name_truncated"]
        expect_module_failure(
            [missing_name_truncation],
            total=1,
            fragment="untruncated name",
        )
        expect_module_failure(
            [loaded_module_record(name="slippicss.dat")],
            total=1,
            fragment="exact module SlippiCSS.dat",
        )

        expect_module_failure(
            [loaded_module_record(byte_count=0)],
            total=1,
            fragment="invalid guest RAM span",
        )
        expect_module_failure(
            [loaded_module_record(address=CHECKER.GUEST_RAM_BASE - 1)],
            total=1,
            fragment="invalid guest RAM span",
        )
        expect_module_failure(
            [loaded_module_record(address=CHECKER.GUEST_RAM_END - 1, byte_count=2)],
            total=1,
            fragment="invalid guest RAM span",
        )

        expect_module_failure(
            [loaded_module_record(first_event=0)],
            total=1,
            fragment="invalid load-event range",
        )
        expect_module_failure(
            [loaded_module_record(loads=0)],
            total=1,
            fragment="invalid load-event range",
        )
        expect_module_failure(
            [loaded_module_record(first_event=2, last_event=1)],
            total=2,
            fragment="invalid load-event range",
        )
        expect_module_failure(
            [loaded_module_record(last_event=2)],
            total=1,
            fragment="invalid load-event range",
        )
        expect_module_failure(
            [loaded_module_record(loads=2)],
            total=2,
            fragment="impossible load-event density",
        )
        expect_module_failure(
            [loaded_module_record(last_event=2)],
            total=2,
            fragment="inconsistent single-load span",
        )
        expect_module_failure(
            [
                loaded_module_record(first_event=2, last_event=2),
                loaded_module_record(
                    name="Other.dat",
                    address=0x80401000,
                    first_event=1,
                    last_event=1,
                ),
            ],
            total=2,
            fragment="ordered by first_event",
        )
        expect_module_failure(
            [
                loaded_module_record(),
                loaded_module_record(first_event=2, last_event=2),
            ],
            total=2,
            fragment="duplicates an earlier identity",
        )

        expect_module_failure(
            [loaded_module_record(sha256_valid=False)],
            total=1,
            fragment="lacks a verified SHA-256",
        )
        expect_module_failure(
            [loaded_module_record(sha256="not-a-64-hex-digest")],
            total=1,
            fragment="lacks a verified SHA-256",
        )
        expect_module_failure(
            [loaded_module_record(sha256="A5" * 32)],
            total=1,
            fragment="lacks a verified SHA-256",
        )
        expect_module_failure(
            [loaded_module_record(sha256="b6" * 32)],
            total=1,
            fragment="does not match the immutable Sys file",
        )
        expect_module_failure(
            [loaded_module_record(byte_count=len(FIXTURE_SLIPPI_CSS_BYTES) - 1)],
            total=1,
            fragment="byte count does not match the immutable Sys file",
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
