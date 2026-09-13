#!/usr/bin/env python3
"""Tests for canonical duplicate hooks and fail-closed HLE absorption."""
# SPDX-License-Identifier: GPL-2.0-or-later
import unittest
from pathlib import Path
import sys

PORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PORT / "recomp"))

import gecko
import recomp


class _Owner:
    name = "PADControlMotor"


class _Symbols:
    def containing(self, address):
        return _Owner() if address == 0x8034DED8 else None


class AbsorbedHooksTest(unittest.TestCase):
    def setUp(self):
        self.gecko_set = recomp.GeckoSet(0x8065CC80)
        self.rumble = next(
            hook for hook in self.gecko_set.main.hooks
            if hook.hook == 0x8034DED8
        )

    def test_identical_duplicate_is_canonicalized_to_later_winner(self):
        duplicates = [
            hook for hook in self.gecko_set.main.hooks
            if hook.hook == 0x8016EA30
        ]
        self.assertEqual(len(duplicates), 2)
        winners, reports = gecko.canonicalize_hooks(duplicates)
        self.assertEqual(len(winners), 1)
        self.assertIs(winners[0], duplicates[-1])
        self.assertEqual(reports, [(0x8016EA30, True)])
        self.assertNotEqual(duplicates[0].words, duplicates[1].words)
        self.assertEqual(
            gecko.canonical_hook_body(duplicates[0]),
            gecko.canonical_hook_body(duplicates[1]),
        )

    def test_pinned_handle_rumble_hook_is_absorbed(self):
        hooks = [self.rumble]
        recomp.validate_absorbed_hooks(hooks, _Symbols(), {"PADControlMotor"})
        self.assertEqual(self.rumble.absorbed_by, "PADControlMotor")

    def test_handle_rumble_fingerprint_drift_fails_closed(self):
        changed = gecko.Hook(
            self.rumble.hook, self.rumble.cave_addr, list(self.rumble.words)
        )
        changed.words[0] ^= 1
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            recomp.validate_absorbed_hooks(
                [changed], _Symbols(), {"PADControlMotor"}
            )

    def test_unregistered_hle_overlap_fails_closed(self):
        unregistered = gecko.Hook(0x8034DED8, self.rumble.cave_addr,
                                  list(self.rumble.words))
        with self.assertRaisesRegex(ValueError, "not registered"):
            recomp.validate_absorbed_hooks(
                [unregistered], _Symbols(), {"PADControlMotor"}, {}
            )


if __name__ == "__main__":
    unittest.main()
