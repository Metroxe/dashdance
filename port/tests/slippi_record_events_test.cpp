// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_record_events.h"
#include <cstdio>

int main() {
  slippi::RecordingEvents e;
  int failures = 0;
  auto check = [&](bool ok) { if (!ok) { ++failures; std::fprintf(stderr, "recording-event assertion failed\n"); } };
  const uint8_t commands[] = {0x35, 4, 0x36, 0, 4};
  const uint8_t start[] = {0x36, 3, 16, 0, 0};
  const uint8_t pre[] = {0x37, 0xFF, 0xFF, 0xFF, 0x85}; // -123
  const uint8_t post[] = {0x38, 0, 0, 0, 1};
  const uint8_t end[] = {0x39, 2};
  check(e.observe(pre, sizeof(pre)) == 0 && !e.has_frames);
  check(e.observe(commands, sizeof(commands) - 1) == 0 && e.commands == 0);
  check(e.observe(commands, sizeof(commands)) == e.Commands && e.commands == 1);
  check(e.observe(start, sizeof(start)) == e.GameStart && e.game_start == 1);
  check(e.observe(pre, 4) == 0 && !e.has_frames);
  check(e.observe(pre, sizeof(pre)) == 0 && e.pre_frame == 1 && e.min_frame == -123);
  check(e.observe(post, sizeof(post)) == e.MatchInputStart && e.post_frame == 1 && e.max_frame == 1);
  check(e.observe(post, sizeof(post)) == 0 && e.post_frame == 2);
  check(e.observe(end, sizeof(end)) == e.GameEnd && e.game_end == 1);
  check(e.observe(commands, sizeof(commands)) == e.Commands && e.commands == 2 &&
        !e.has_frames && e.game_start == 0 && e.post_frame == 0 && !e.match_input_started);
  check(e.observe(nullptr, 100) == 0);
  return failures ? 1 : 0;
}
