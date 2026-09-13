#!/usr/bin/env python3
"""Validate an offline Melee menu-to-match run from scene bytes and a Slippi replay.

GX counts, elapsed retraces, and process survival are deliberately not gameplay
evidence here.  The scene bytes are the pinned GALE01 state machine at
0x80479D30 (current mode) and 0x80479D33 (current state id).  Match
evidence comes independently from the raw event stream in the emitted .slp.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import struct
from typing import Iterable


SCENE_MODE_ADDRESS = 0x80479D30
SCENE_STATE_ADDRESS = 0x80479D33
GCT_ADDRESS = 0x8065CC80
GUEST_RAM_BASE = 0x80000000
GUEST_RAM_END = 0x81800000
MAX_LOADED_MODULES = 128
MAX_LOADED_MODULE_NAME_BYTES = 95
SLIPPI_CSS_SYS_PATH = "GameFiles/GALE01/SlippiCSS.dat"
REQUIRED_SLIPPI_INPUTS = frozenset(
    {"codehandler.bin", "bootloader.gct", "GameSettings/GALE01r2.ini"}
)
ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE_SCRIPT = ROOT / "port" / "scripts" / "offline_vs_acceptance.txt"

MILESTONES = (
    ("boot", 0x28, 0x00),
    ("main-menu", 0x01, 0x00),
    ("vs-css", 0x02, 0x00),
    ("sss", 0x02, 0x01),
    ("in-game", 0x02, 0x02),
    ("results", 0x02, 0x04),
)

CMD_COMMANDS = 0x35
CMD_GAME_START = 0x36
CMD_PRE_FRAME = 0x37
CMD_POST_FRAME = 0x38
CMD_GAME_END = 0x39
CMD_FRAME_BOOKEND = 0x3C

SCENE_RE = re.compile(
    r"^"
    r"accept: scene retrace=(\d+) mode_byte=0x([0-9a-fA-F]{2}) "
    r"state_byte=0x([0-9a-fA-F]{2}) combined=0x([0-9a-fA-F]{4})$",
    re.MULTILINE,
)
AOT_RE = re.compile(
    r"^\[aot\] strict=yes missing-target attempts=0 interpreted calls=0 instructions=0$",
    re.MULTILINE,
)


class AcceptanceFailure(ValueError):
    pass


@dataclass(frozen=True)
class SceneSample:
    retrace: int
    mode_byte: int
    state_byte: int
    combined: int


@dataclass(frozen=True)
class ReplaySummary:
    raw_bytes: int
    event_counts: dict[int, int]
    first_event_index: dict[int, int]
    configured_sizes: dict[int, int]
    min_pre_frame: int | None
    max_pre_frame: int | None
    min_post_frame: int | None
    max_post_frame: int | None
    min_bookend_frame: int | None
    max_bookend_frame: int | None
    max_complete_frame: int | None
    last_frame_event_index: int
    first_game_end_index: int | None

    def count(self, command: int) -> int:
        return self.event_counts.get(command, 0)


@dataclass(frozen=True)
class AcceptanceReport:
    through: str
    scenes: tuple[SceneSample, ...]
    reached: tuple[str, ...]
    replay: ReplaySummary


def _fail(message: str) -> None:
    raise AcceptanceFailure(message)


def _digest(path: Path, algorithm: str = "sha256") -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def _valid_sha256_inventory(value: object) -> bool:
    return (
        isinstance(value, dict)
        and bool(value)
        and all(
            isinstance(name, str)
            and bool(name)
            and isinstance(digest, str)
            and re.fullmatch(r"[0-9a-f]{64}", digest) is not None
            for name, digest in value.items()
        )
    )


def _load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        _fail(f"cannot read structured run evidence {path}: {error}")
    if not isinstance(value, dict):
        _fail(f"structured run evidence is not an object: {path}")
    return value


def _require_run_evidence(log_path: Path, replay_path: Path) -> dict:
    """Bind the log and replay to one immutable, isolated runtime result."""
    try:
        log = log_path.resolve(strict=True)
        replay = replay_path.resolve(strict=True)
    except OSError as error:
        _fail(f"cannot resolve run artifacts: {error}")
    cache = log.parent
    replay_dir = cache / "replays"
    if replay.parent != replay_dir:
        _fail("log and replay are not in the same isolated cache/replays tree")

    launch_path = cache / "launch.json"
    result_path = cache / "result.json"
    launch = _load_json(launch_path)
    result = _load_json(result_path)
    if launch.get("schema") != "melee-native-headless-run-v1" or launch.get("phase") != "prepared":
        _fail("launch.json is not a prepared native headless run manifest")
    if result.get("schema") != launch["schema"] or result.get("phase") != "finished":
        _fail("result.json is not the finished form of launch.json")
    immutable = (
        "command", "executable", "input_manifest", "upstream_pin",
        "decomp_pin", "gct_base", "bounds", "capabilities", "fp_profile",
        "isolation", "outputs",
    )
    for key in immutable:
        if result.get(key) != launch.get(key):
            _fail(f"launch/result manifests disagree on immutable field {key}")
    result_inputs = dict(result.get("inputs", {}))
    actual_dol = result_inputs.pop("dol_actual_sha1", None)
    dol_verified = result_inputs.pop("dol_verified", None)
    if result_inputs != launch.get("inputs"):
        _fail("launch/result manifests disagree on immutable field inputs")
    if dol_verified is not True or actual_dol != result_inputs.get("dol_expected_sha1"):
        _fail("runtime DOL did not match the pinned build input")

    isolation = result.get("isolation", {})
    outputs = result.get("outputs", {})
    if isolation.get("cache_dir") != str(cache):
        _fail("result manifest cache directory does not identify the supplied log")
    if isolation.get("replay_dir") != str(replay_dir):
        _fail("result manifest replay directory does not identify the supplied replay")
    if outputs.get("log") != str(log):
        _fail("result manifest log path does not identify the supplied log")
    if result.get("capabilities", {}).get("offline") is not True:
        _fail("run manifest does not declare the offline capability boundary")
    if result.get("capabilities", {}).get("strict_aot") is not True:
        _fail("run manifest does not declare strict AOT")
    acceptance = result.get("acceptance", {})
    if (
        launch.get("acceptance", {}).get("expect_scene") is not True
        or launch.get("acceptance", {}).get("expected_combined") != 0x0202
        or acceptance.get("expect_scene") is not True
        or acceptance.get("expected_combined") != 0x0202
        or acceptance.get("scene_observed") is not True
    ):
        _fail("run result did not satisfy --expect-scene 0x0202")
    inputs = result.get("inputs", {})
    if inputs.get("slippi_sys_tree_verified") is not True:
        _fail("runtime Sys tree was not verified against the build manifest")
    slippi_inputs = inputs.get("slippi")
    if (
        not isinstance(slippi_inputs, dict)
        or set(slippi_inputs) != REQUIRED_SLIPPI_INPUTS
        or any(
            not isinstance(item, dict)
            or item.get("verified") is not True
            or item.get("sha256") != item.get("build_sha256")
            for item in slippi_inputs.values()
        )
    ):
        _fail("runtime Slippi inputs were not verified against build inputs")
    slippi_sys_files = inputs.get("slippi_sys_files_sha256")
    if not _valid_sha256_inventory(slippi_sys_files):
        _fail("runtime inputs lack a valid immutable Slippi Sys inventory")
    if any(
        slippi_inputs[name].get("sha256") != slippi_sys_files.get(name)
        for name in REQUIRED_SLIPPI_INPUTS
    ):
        _fail("direct runtime Slippi inputs disagree with the immutable Sys inventory")
    expected_slippi_css_sha256 = (
        slippi_sys_files.get(SLIPPI_CSS_SYS_PATH)
        if isinstance(slippi_sys_files, dict)
        else None
    )
    if (
        not isinstance(expected_slippi_css_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", expected_slippi_css_sha256) is None
    ):
        _fail("runtime inputs lack the immutable SlippiCSS.dat SHA-256")

    exit_evidence = result.get("exit", {})
    if exit_evidence.get("code") != 0 or exit_evidence.get("orderly_shutdown") is not True:
        _fail("structured run result is not an orderly exit=0")
    counters = result.get("counters", {})
    aot = counters.get("aot", {})
    if aot.get("strict") is not True or any(
        type(aot.get(field)) is not int or aot.get(field) != 0
        for field in (
            "missing_attempts", "interpreted_calls", "interpreted_instructions",
            "unrecorded_attempts", "unrecorded_pc_visits",
        )
    ):
        _fail("structured run result does not prove strict AOT zero fallback")
    loaded_module_records = aot.get("loaded_module_records")
    unrecorded_modules = aot.get("unrecorded_modules")
    loaded_modules = aot.get("modules")
    if (
        type(loaded_module_records) is not int
        or loaded_module_records < 0
        or type(unrecorded_modules) is not int
        or unrecorded_modules < 0
        or not isinstance(loaded_modules, list)
    ):
        _fail("structured AOT loaded-module counters/list are invalid")
    if not 1 <= len(loaded_modules) <= MAX_LOADED_MODULES:
        _fail(
            "offline gameplay acceptance requires 1..128 retained loaded-module identities"
        )
    loaded_events = 0
    previous_first_event = 0
    identities: set[tuple[str, int, int, str]] = set()
    slippi_css_modules: list[dict] = []
    for index, module in enumerate(loaded_modules):
        if not isinstance(module, dict):
            _fail(f"structured AOT loaded module {index} is not an object")
        name = module.get("name")
        if not isinstance(name, str) or not name.strip() or "\x00" in name:
            _fail(f"structured AOT loaded module {index} has an invalid bounded name")
        try:
            name_bytes = name.encode("utf-8")
        except UnicodeEncodeError:
            _fail(f"structured AOT loaded module {index} has an invalid bounded name")
        if len(name_bytes) > MAX_LOADED_MODULE_NAME_BYTES:
            _fail(f"structured AOT loaded module {index} has an invalid bounded name")
        if module.get("name_truncated") is not False:
            _fail(f"structured AOT loaded module {index} does not have an untruncated name")
        address = module.get("address")
        byte_count = module.get("bytes")
        if (
            type(address) is not int
            or type(byte_count) is not int
            or byte_count <= 0
            or address < GUEST_RAM_BASE
            or address + byte_count > GUEST_RAM_END
        ):
            _fail(f"structured AOT loaded module {index} has an invalid guest RAM span")
        if (
            module.get("sha256_valid") is not True
            or not isinstance(module.get("sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", module["sha256"]) is None
        ):
            _fail(f"structured AOT loaded module {index} lacks a verified SHA-256")
        loads = module.get("loads")
        first_event = module.get("first_event")
        last_event = module.get("last_event")
        if (
            type(loads) is not int
            or type(first_event) is not int
            or type(last_event) is not int
            or loads < 1
            or first_event < 1
            or first_event > last_event
            or last_event > loaded_module_records
        ):
            _fail(f"structured AOT loaded module {index} has an invalid load-event range")
        if loads > last_event - first_event + 1:
            _fail(f"structured AOT loaded module {index} has impossible load-event density")
        if loads == 1 and first_event != last_event:
            _fail(f"structured AOT loaded module {index} has an inconsistent single-load span")
        if first_event <= previous_first_event:
            _fail("structured AOT loaded modules are not ordered by first_event")
        previous_first_event = first_event
        identity = (name, address, byte_count, module["sha256"])
        if identity in identities:
            _fail(f"structured AOT loaded module {index} duplicates an earlier identity")
        identities.add(identity)
        loaded_events += loads
        if name == "SlippiCSS.dat":
            if module["sha256"] != expected_slippi_css_sha256:
                _fail(
                    "structured AOT SlippiCSS.dat SHA-256 does not match the immutable Sys file"
                )
            slippi_css_modules.append(module)
    if loaded_events + unrecorded_modules != loaded_module_records:
        _fail("structured AOT loaded-module load-event accounting is inconsistent")
    if unrecorded_modules != 0:
        _fail("offline gameplay acceptance requires unrecorded_modules=0")
    if not slippi_css_modules:
        _fail("structured AOT evidence does not include exact module SlippiCSS.dat")
    slippi = counters.get("slippi", {})
    if slippi.get("gct_load_address") != GCT_ADDRESS:
        _fail(f"structured run result has the wrong GCT address (expected 0x{GCT_ADDRESS:08X})")
    if slippi.get("replays_written") != 1:
        _fail("structured run result must report exactly one replay")
    if result.get("gct_base") != GCT_ADDRESS:
        _fail("compiled GCT base and runtime GCT load evidence disagree")

    try:
        executable = Path(result["executable"]["path"]).resolve(strict=True)
        input_manifest = Path(result["input_manifest"]["path"]).resolve(strict=True)
    except (KeyError, OSError, TypeError) as error:
        _fail(f"run identity paths are invalid: {error}")
    if _digest(executable) != result["executable"].get("sha256"):
        _fail("current executable hash differs from the run manifest")
    actual_manifest_hash = _digest(input_manifest)
    manifest_identity = result["input_manifest"]
    if (
        actual_manifest_hash != manifest_identity.get("actual_sha256")
        or actual_manifest_hash != manifest_identity.get("compiled_sha256")
    ):
        _fail("current input manifest is not the one compiled into the executable")
    build_inputs = _load_json(input_manifest)
    build_sys_files = build_inputs.get("slippi_sys_files_sha256")
    sys_dir_value = build_inputs.get("slippi_sys_dir")
    if not _valid_sha256_inventory(build_sys_files):
        _fail("build input manifest lacks a valid immutable Slippi Sys inventory")
    if build_sys_files != slippi_sys_files:
        _fail("build and runtime Slippi Sys inventories disagree")
    if not isinstance(sys_dir_value, str) or not sys_dir_value:
        _fail("build input manifest does not identify the immutable Slippi Sys directory")
    try:
        sys_dir = Path(sys_dir_value).resolve(strict=True)
    except OSError as error:
        _fail(f"cannot resolve current immutable Slippi Sys directory: {error}")
    if not sys_dir.is_dir():
        _fail("current immutable Slippi Sys path is not a directory")
    current_sys_files: dict[str, str] = {}
    try:
        for path in sorted(sys_dir.rglob("*")):
            if path.is_symlink():
                _fail("current immutable Slippi Sys tree must not contain symlinks")
            if path.is_file():
                current_sys_files[path.relative_to(sys_dir).as_posix()] = _digest(path)
    except OSError as error:
        _fail(f"cannot hash current immutable Slippi Sys tree: {error}")
    if current_sys_files != build_sys_files:
        _fail("current Slippi Sys inventory or contents do not match the build manifest")
    css_source = sys_dir / SLIPPI_CSS_SYS_PATH
    try:
        css_source = css_source.resolve(strict=True)
        css_source.relative_to(sys_dir)
        css_source_bytes = css_source.stat().st_size
        css_source_sha256 = _digest(css_source)
    except (OSError, ValueError) as error:
        _fail(f"cannot resolve current immutable SlippiCSS.dat file: {error}")
    if css_source_sha256 != expected_slippi_css_sha256:
        _fail("current SlippiCSS.dat file does not match the immutable Sys SHA-256")
    if any(module["bytes"] != css_source_bytes for module in slippi_css_modules):
        _fail("structured AOT SlippiCSS.dat byte count does not match the immutable Sys file")
    sidecar = _load_json(executable.with_name(executable.name + ".verified.json"))
    if (
        sidecar.get("verified") is not True
        or sidecar.get("binary") != str(executable)
        or sidecar.get("binary_sha256") != result["executable"].get("sha256")
        or sidecar.get("input_manifest") != str(input_manifest)
        or sidecar.get("input_manifest_sha256") != actual_manifest_hash
    ):
        _fail("binary verification sidecar does not bind this run to its build inputs")

    script = result.get("inputs", {}).get("script", {})
    try:
        expected_script = ACCEPTANCE_SCRIPT.resolve(strict=True)
        recorded_script = Path(script["path"]).resolve(strict=True)
    except (KeyError, OSError, TypeError) as error:
        _fail(f"run did not identify the offline acceptance script: {error}")
    if recorded_script != expected_script or script.get("sha1") != _digest(expected_script, "sha1"):
        _fail("run did not use the current canonical offline acceptance script")

    artifacts = result.get("artifacts", {})
    log_identity = artifacts.get("log", {})
    if (
        log_identity.get("closed") is not True
        or log_identity.get("path") != str(log)
        or log_identity.get("bytes") != log.stat().st_size
        or log_identity.get("sha256") != _digest(log)
    ):
        _fail("result manifest does not bind the supplied log by path, size, and hash")
    replay_identity = artifacts.get("replay", {})
    if (
        artifacts.get("replay_status") != "closed"
        or replay_identity.get("closed") is not True
        or replay_identity.get("path") != str(replay)
        or replay_identity.get("bytes") != replay.stat().st_size
        or replay_identity.get("sha256") != _digest(replay)
    ):
        _fail("result manifest does not bind the supplied replay by path, size, and hash")
    return result


def _structured_scenes(result: dict) -> tuple[SceneSample, ...]:
    evidence = result.get("scenes", {})
    if (
        evidence.get("mode_address") != SCENE_MODE_ADDRESS
        or evidence.get("state_address") != SCENE_STATE_ADDRESS
    ):
        _fail("structured scene evidence has the wrong GALE01 addresses")
    if evidence.get("unrecorded") != 0:
        _fail("structured scene timeline overflowed its bounded storage")
    timeline = evidence.get("timeline")
    if not isinstance(timeline, list) or evidence.get("transitions") != len(timeline):
        _fail("structured scene transition count disagrees with its timeline")
    samples: list[SceneSample] = []
    for item in timeline:
        try:
            sample = SceneSample(
                retrace=int(item["retrace"]),
                mode_byte=int(item["mode_byte"]),
                state_byte=int(item["state_byte"]),
                combined=int(item["combined"]),
            )
        except (KeyError, TypeError, ValueError) as error:
            _fail(f"malformed structured scene entry: {error}")
        if not (0 <= sample.mode_byte <= 0xFF and 0 <= sample.state_byte <= 0xFF):
            _fail("structured scene byte is outside 0..255")
        expected = (sample.state_byte << 8) | sample.mode_byte
        if sample.combined != expected:
            _fail("structured scene combined value disagrees with its raw bytes")
        samples.append(sample)
    if not samples:
        _fail("structured result contains no scene-byte telemetry")
    for previous, current in zip(samples, samples[1:]):
        if current.retrace < previous.retrace:
            _fail("structured scene timeline retraces are not monotonic")
    if not any(sample.combined == 0x0202 for sample in samples):
        _fail("structured timeline does not contain expected offline scene 0x0202")
    return tuple(samples)


def parse_scene_log(text: str) -> tuple[SceneSample, ...]:
    samples = tuple(
        SceneSample(
            int(match.group(1)),
            int(match.group(2), 16),
            int(match.group(3), 16),
            int(match.group(4), 16),
        )
        for match in SCENE_RE.finditer(text)
    )
    if not samples:
        _fail(
            "no scene-byte telemetry; retrace/GX survival does not establish gameplay "
            f"(expected 0x{SCENE_MODE_ADDRESS:08X} and 0x{SCENE_STATE_ADDRESS:08X})"
        )
    for sample in samples:
        expected = (sample.state_byte << 8) | sample.mode_byte
        if sample.combined != expected:
            _fail(
                "scene telemetry packed value disagrees with its bytes "
                f"at retrace {sample.retrace}: combined=0x{sample.combined:04X}, "
                f"expected 0x{expected:04X}"
            )
    for previous, current in zip(samples, samples[1:]):
        if current.retrace < previous.retrace:
            _fail("scene timeline retraces are not monotonic")
    return samples


def _raw_stream(data: bytes, source: Path) -> bytes:
    header = b"{U\x03raw[$U#l"
    if len(data) < 15 or data[:11] != header:
        _fail(f"{source}: not a Slippi UBJSON replay")
    raw_size = struct.unpack_from(">I", data, 11)[0]
    if raw_size == 0:
        _fail(f"{source}: empty Slippi raw event stream")
    if 15 + raw_size > len(data):
        _fail(f"{source}: truncated Slippi raw event stream")
    return data[15 : 15 + raw_size]


def _signed_frame(payload: bytes) -> int:
    return struct.unpack_from(">i", payload)[0]


def parse_replay(path: Path) -> ReplaySummary:
    try:
        raw = _raw_stream(path.read_bytes(), path)
    except OSError as error:
        _fail(f"cannot read replay {path}: {error}")

    sizes: dict[int, int] = {}
    counts: dict[int, int] = {}
    first: dict[int, int] = {}
    pre_frames: list[int] = []
    post_frames: list[int] = []
    bookend_frames: list[int] = []
    pre_events: dict[int, list[int]] = {}
    post_events: dict[int, list[int]] = {}
    bookend_events: dict[int, list[int]] = {}
    frame_event_indices: list[int] = []
    game_end_indices: list[int] = []
    position = 0
    event_index = 0
    while position < len(raw):
        command = raw[position]
        if command == CMD_COMMANDS:
            if position + 2 > len(raw):
                _fail(f"{path}: truncated command-size event")
            payload_size = raw[position + 1]
            total_size = payload_size + 1
            if payload_size < 1 or (payload_size - 1) % 3:
                _fail(f"{path}: malformed command-size table")
        else:
            if command not in sizes:
                _fail(f"{path}: raw event 0x{command:02X} has no configured size")
            payload_size = sizes[command]
            total_size = payload_size + 1
        if position + total_size > len(raw):
            _fail(f"{path}: truncated raw event 0x{command:02X}")

        payload = raw[position + 1 : position + total_size]
        counts[command] = counts.get(command, 0) + 1
        first.setdefault(command, event_index)
        if command == CMD_COMMANDS:
            if counts[command] != 1 or position != 0:
                _fail(f"{path}: command-size table must be the first and only 0x35 event")
            for offset in range(1, len(payload), 3):
                configured_command = payload[offset]
                configured_size = (payload[offset + 1] << 8) | payload[offset + 2]
                if configured_command in sizes:
                    _fail(f"{path}: duplicate configured event 0x{configured_command:02X}")
                sizes[configured_command] = configured_size
        elif command == CMD_PRE_FRAME:
            if len(payload) < 4:
                _fail(f"{path}: pre-frame event cannot contain a frame number")
            frame = _signed_frame(payload[:4])
            pre_frames.append(frame)
            pre_events.setdefault(frame, []).append(event_index)
            frame_event_indices.append(event_index)
        elif command == CMD_POST_FRAME:
            if len(payload) < 4:
                _fail(f"{path}: post-frame event cannot contain a frame number")
            frame = _signed_frame(payload[:4])
            post_frames.append(frame)
            post_events.setdefault(frame, []).append(event_index)
            frame_event_indices.append(event_index)
        elif command == CMD_FRAME_BOOKEND:
            if len(payload) < 4:
                _fail(f"{path}: frame-bookend event cannot contain a frame number")
            frame = _signed_frame(payload[:4])
            bookend_frames.append(frame)
            bookend_events.setdefault(frame, []).append(event_index)
            frame_event_indices.append(event_index)
        elif command == CMD_GAME_END:
            game_end_indices.append(event_index)

        position += total_size
        event_index += 1

    def bound(values: list[int], chooser) -> int | None:
        return chooser(values) if values else None

    complete_frames: list[int] = []
    for frame in sorted(set(pre_events) & set(post_events) & set(bookend_events)):
        # At least one same-frame pre/post/bookend chain must exist in raw-event
        # order. Multiple players legitimately emit multiple pre/post records.
        if any(
            pre_index < post_index < bookend_index
            for pre_index in pre_events[frame]
            for post_index in post_events[frame]
            for bookend_index in bookend_events[frame]
        ):
            complete_frames.append(frame)

    return ReplaySummary(
        raw_bytes=len(raw),
        event_counts=counts,
        first_event_index=first,
        configured_sizes=sizes,
        min_pre_frame=bound(pre_frames, min),
        max_pre_frame=bound(pre_frames, max),
        min_post_frame=bound(post_frames, min),
        max_post_frame=bound(post_frames, max),
        min_bookend_frame=bound(bookend_frames, min),
        max_bookend_frame=bound(bookend_frames, max),
        max_complete_frame=bound(complete_frames, max),
        last_frame_event_index=max(frame_event_indices, default=-1),
        first_game_end_index=min(game_end_indices) if game_end_indices else None,
    )


def _ordered_milestones(
    samples: Iterable[SceneSample], through: str
) -> tuple[str, ...]:
    target = next(index for index, item in enumerate(MILESTONES) if item[0] == through)
    required = MILESTONES[: target + 1]
    cursor = 0
    reached: list[str] = []
    for sample in samples:
        if cursor == len(required):
            break
        name, mode_byte, state_byte = required[cursor]
        if (sample.mode_byte, sample.state_byte) == (mode_byte, state_byte):
            reached.append(name)
            cursor += 1
    if cursor != len(required):
        name, mode_byte, state_byte = required[cursor]
        observed = " ".join(
            f"{sample.mode_byte:02X}:{sample.state_byte:02X}" for sample in samples
        )
        _fail(
            f"missing ordered scene milestone {name}={mode_byte:02X}:{state_byte:02X}; "
            f"observed: {observed}"
        )
    return tuple(reached)


def _require_replay_events(summary: ReplaySummary, through: str, min_game_frame: int) -> None:
    for command, name in (
        (CMD_COMMANDS, "command table/create"),
        (CMD_GAME_START, "game start"),
        (CMD_PRE_FRAME, "pre-frame"),
        (CMD_POST_FRAME, "post-frame"),
        (CMD_FRAME_BOOKEND, "frame bookend"),
    ):
        if not summary.count(command):
            _fail(f"replay has no Slippi {name} event (0x{command:02X})")

    if summary.count(CMD_COMMANDS) != 1 or summary.count(CMD_GAME_START) != 1:
        _fail("replay must contain exactly one command table and one game-start event")
    if summary.first_event_index[CMD_GAME_START] >= min(
        summary.first_event_index[command]
        for command in (CMD_PRE_FRAME, CMD_POST_FRAME, CMD_FRAME_BOOKEND)
    ):
        _fail("Slippi game-start event does not precede frame data")
    if summary.max_pre_frame is None or summary.max_post_frame is None:
        _fail("Slippi frame bounds are unavailable")
    if summary.max_complete_frame is None or summary.max_complete_frame < min_game_frame:
        _fail(
            f"replay has no ordered same-frame pre/post/bookend chain at gameplay "
            f"frame {min_game_frame} or later (pre={summary.max_pre_frame}, "
            f"post={summary.max_post_frame}, bookend={summary.max_bookend_frame})"
        )
    if summary.count(CMD_GAME_END) > 1:
        _fail("replay has more than one Slippi game-end event")
    if (
        summary.first_game_end_index is not None
        and summary.first_game_end_index <= summary.last_frame_event_index
    ):
        _fail("Slippi game-end event does not follow all frame data")
    if through == "results":
        if not summary.count(CMD_GAME_END):
            _fail("results acceptance requires a Slippi game-end event (0x39)")


def check_acceptance(
    log_path: Path,
    replay_path: Path,
    *,
    through: str = "in-game",
    min_game_frame: int = 1,
) -> AcceptanceReport:
    if through not in {"in-game", "results"}:
        _fail("through must be in-game or results")
    if min_game_frame < 1:
        _fail("minimum gameplay frame must be positive")
    result = _require_run_evidence(log_path, replay_path)
    try:
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        _fail(f"cannot read log {log_path}: {error}")

    if not re.search(r"^headless result: exit=0 retraces=\d+ requested=\d+$", log_text, re.MULTILINE):
        _fail("headless process did not report exit=0")
    if not AOT_RE.search(log_text):
        _fail("strict AOT zero-fallback result is absent")
    if not re.search(r"^slippi: game loads the GCT .* at 8065CC80(?:\s.*)?$", log_text, re.MULTILINE):
        _fail(f"runtime did not verify the pinned GCT address 0x{GCT_ADDRESS:08X}")
    if re.search(r"(?:^|\n)(?:FATAL:|host exception:)", log_text):
        _fail("fatal runtime diagnostic present")

    log_scenes = parse_scene_log(log_text)
    scenes = _structured_scenes(result)
    if scenes != log_scenes:
        _fail("runtime log scene transitions disagree with structured result.json evidence")
    if scenes[-1].retrace > result.get("counters", {}).get("retraces", -1):
        _fail("scene timeline extends beyond the structured retrace count")
    reached = _ordered_milestones(scenes, through)
    replay = parse_replay(replay_path)
    _require_replay_events(replay, through, min_game_frame)
    recording = result.get("recording", {})
    expected_counts = {
        "commands": replay.count(CMD_COMMANDS),
        "game_start": replay.count(CMD_GAME_START),
        "pre_frame": replay.count(CMD_PRE_FRAME),
        "post_frame": replay.count(CMD_POST_FRAME),
        "game_end": replay.count(CMD_GAME_END),
    }
    if any(recording.get(name) != count for name, count in expected_counts.items()):
        _fail("structured recording counters disagree with the replay event stream")
    observed_bounds = [
        value
        for value in (
            replay.min_pre_frame,
            replay.max_pre_frame,
            replay.min_post_frame,
            replay.max_post_frame,
        )
        if value is not None
    ]
    if (
        recording.get("has_frames") is not True
        or recording.get("min_frame") != min(observed_bounds)
        or recording.get("max_frame") != max(observed_bounds)
        or recording.get("match_input_started") is not True
    ):
        _fail("structured recording frame evidence disagrees with the replay")
    return AcceptanceReport(through, scenes, reached, replay)


def _one_replay(path: Path) -> Path:
    if path.is_file():
        return path
    if not path.is_dir():
        _fail(f"replay path does not exist: {path}")
    matches = sorted(path.glob("*.slp"))
    if len(matches) != 1:
        _fail(f"expected exactly one .slp in {path}, found {len(matches)}")
    return matches[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--replay", type=Path, required=True, help="one .slp file or a directory containing exactly one")
    parser.add_argument("--through", choices=("in-game", "results"), default="in-game")
    parser.add_argument("--min-game-frame", type=int, default=1)
    args = parser.parse_args(argv)
    try:
        replay = _one_replay(args.replay)
        report = check_acceptance(
            args.log,
            replay,
            through=args.through,
            min_game_frame=args.min_game_frame,
        )
    except AcceptanceFailure as error:
        parser.exit(1, f"FAIL: {error}\n")
    summary = report.replay
    print(
        f"PASS offline gameplay through {report.through}: "
        f"scenes={' -> '.join(report.reached)}; "
        f"pre={summary.count(CMD_PRE_FRAME)} post={summary.count(CMD_POST_FRAME)} "
        f"bookend={summary.count(CMD_FRAME_BOOKEND)} max_frame={summary.max_post_frame}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
