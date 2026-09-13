// The real online owner, compiled without any host/profile/transport dependency.
// This test must link slippi_online.cpp + slippi_offline.cpp only. A new call to
// identity/reporting/ENet therefore fails the link instead of silently succeeding.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_online.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <vector>

namespace {
int failures = 0;
void check(bool condition, const char* message) {
  if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}
}

int main() {
  using namespace slippi::online;
  check(!available(), "diagnostic build must never advertise online capability");
  check(config().offline, "service configuration defaults to offline");
  // Deliberately nonexistent: construction must not probe, create or load it.
  config().user_dir = "/slippi-offline-test-must-not-be-accessed/profile";
  config().delay = 4;
  config().offline_seed = 0x12345678;
  shutdown();
  init();
  init();
  check(!is_online_match() && rollback_count() == 0, "offline init must have no match or rollback");

  std::array<uint8_t, 368> payload{};
  std::vector<uint8_t> q;
  check(handle(0xB9, nullptr, 0, q) && q.size() == 42 &&
        std::all_of(q.begin(), q.end(), [](uint8_t b) { return b == 0; }),
        "offline status must be logged out with no identity");
  check(handle(0xB0, nullptr, 0, q) && q == std::vector<uint8_t>{3},
        "online input request must report disconnected without dereferencing payload");
  check(handle(0xB3, nullptr, 0, q) && q.size() == 962 && q[0] == 5 &&
        q[1] == 0 && q[2] == 0 && q[9] == 4 && q[357] == 'O',
        "match state must report offline error with no ready players");
  check(handle(0xE3, nullptr, 0, q) && q.size() == 16 && q[1] == 2,
        "rank must report fetch error, never a fetched rank");
  check(handle(0xC1, nullptr, 0, q) && q.size() == 6 && q[0] == 0,
        "game preparation must not invent a remote result");
  check(handle(0xC3, nullptr, 0, q) && q.size() == 3264,
        "player settings must preserve the EXI response length");
  check(handle(0xD5, nullptr, 0, q) && q == std::vector<uint8_t>({1, 4}),
        "offline local delay remains available");

  payload[0] = 'A'; payload[24] = 1; payload[28] = 7;
  check(handle(0xBE, payload.data(), 31, q) && q.size() == 30 && q[0] == 0 &&
        q[1] == 'A' && q[25] == 1 && q[29] == 7,
        "direct code text survives without reading code history");
  payload[24] = 255;
  check(handle(0xBE, payload.data(), 31, q) && q.size() == 30 && q[25] == 0,
        "invalid name length must not cause an out-of-bounds copy");
  check(handle(0xBE, nullptr, 0, q) && q.size() == 30 && q[25] == 0,
        "missing suggestion payload must remain bounded");

  for (uint8_t cmd : {0xB1, 0xB2, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xBA,
                      0xBB, 0xBD, 0xBF, 0xC0, 0xC2, 0xC4, 0xE4}) {
    q.assign(42, 1);
    check(handle(cmd, nullptr, 0, q) && q.empty(), "offline action must not create an acknowledgement");
  }
  q = {0xAA};
  check(!handle(0x75, nullptr, 0, q) && q == std::vector<uint8_t>{0xAA},
        "replay command remains owned by playback");
  check(!handle(0xD6, nullptr, 0, q), "music command remains owned by jukebox");
  handle(0xBC, nullptr, 0, q);
  const auto first_seed = q;
  handle(0xBC, nullptr, 0, q);
  check(first_seed.size() == 4 && q != first_seed, "local seed requests advance the generator");

  // Even an explicit runtime request cannot add transports excluded by the build.
  config().offline = false;
  config().delay = 9;
  check(handle(0xD5, nullptr, 0, q) && q[1] == 4, "configuration is latched until shutdown");
  shutdown();
  shutdown();
  init();
  check(!available() && !is_online_match(), "online remains unavailable after reinitialization");
  check(handle(0xB9, nullptr, 0, q) && q[0] == 0, "reinitialization cannot load identity");
  handle(0xBC, nullptr, 0, q);
  check(q == first_seed, "offline seed sequence is repeatable across lifecycle resets");
  check(handle(0xD5, nullptr, 0, q) && q[1] == 9, "reinitialization applies local configuration");
  shutdown();
  return failures ? 1 : 0;
}
