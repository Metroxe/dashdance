// Focused parity checks for Slippi Online/Core/HandleRumble.asm.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "pad_rumble.h"

#include <array>
#include <cstdio>

namespace {

int failures = 0;

void check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    ++failures;
  }
}

template <size_t N>
void write_be32(std::array<uint8_t, N>& ram, size_t offset, uint32_t value) {
  ram[offset] = uint8_t(value >> 24);
  ram[offset + 1] = uint8_t(value >> 16);
  ram[offset + 2] = uint8_t(value >> 8);
  ram[offset + 3] = uint8_t(value);
}

}  // namespace

int main() {
  using hle::pad::decide_rumble;
  constexpr uint32_t kRamBase = 0x80000000;
  constexpr uint32_t kOdbSlot = kRamBase + 0x100;
  constexpr uint32_t kR13 = kOdbSlot + 0x49E4;
  constexpr uint32_t kOdb = kRamBase + 0x200;
  std::array<uint8_t, 0x400> ram{};
  write_be32(ram, 0x100, kOdb);
  ram[0x200] = 1;  // logical local-player index
  ram[0x202] = 0;  // physical input-source index

  for (uint32_t command : {0u, 1u, 2u}) {
    const auto offline = decide_rumble(2, command, 0x02, 0x02, 0, nullptr, 0);
    check(offline.deliver && offline.physical_port == 2,
          "offline scenes preserve the original controller port");
    check(offline.on == (command == 1),
          "commands 0/1/2 map to stop/start/stop-hard adapter state");

    const auto local = decide_rumble(1, command, 0x08, 0x02, kR13,
                                     ram.data(), ram.size());
    check(local.deliver && local.physical_port == 0,
          "online local logical port remaps to the physical input source");
    check(local.on == (command == 1),
          "online remap preserves the motor command");
  }

  check(!decide_rumble(0, 1, 0x08, 0x02, kR13, ram.data(), ram.size()).deliver,
        "online remote logical-player rumble is suppressed");
  check(decide_rumble(1, 1, 0x08, 0x03, 0, nullptr, 0).deliver,
        "only exact scene 0x0208 enables Slippi remapping");

  check(!decide_rumble(4, 1, 0x02, 0x02, 0, nullptr, 0).deliver,
        "invalid logical ports are rejected offline");
  ram[0x200] = 4;
  check(!decide_rumble(1, 1, 0x08, 0x02, kR13, ram.data(), ram.size()).deliver,
        "invalid local-player indices are rejected");
  ram[0x200] = 1;
  ram[0x202] = 4;
  check(!decide_rumble(1, 1, 0x08, 0x02, kR13, ram.data(), ram.size()).deliver,
        "invalid physical input-source indices are rejected");
  ram[0x202] = 0;

  check(!decide_rumble(1, 1, 0x08, 0x02, 0x100, ram.data(), ram.size()).deliver,
        "an r13 offset underflow is rejected");
  write_be32(ram, 0x100, 0);
  check(!decide_rumble(1, 1, 0x08, 0x02, kR13, ram.data(), ram.size()).deliver,
        "a null ODB pointer is rejected");
  write_be32(ram, 0x100, kOdb);
  check(!decide_rumble(1, 1, 0x08, 0x02,
                       kRamBase + uint32_t(ram.size() - 2) + 0x49E4,
                       ram.data(), ram.size()).deliver,
        "an out-of-bounds ODB pointer slot is rejected");
  write_be32(ram, 0x100, kRamBase + uint32_t(ram.size() - 2));
  check(!decide_rumble(1, 1, 0x08, 0x02, kR13, ram.data(), ram.size()).deliver,
        "an out-of-bounds ODB record is rejected");
  check(!decide_rumble(1, 1, 0x08, 0x02, kR13, nullptr, ram.size()).deliver,
        "a missing guest RAM view is rejected");

  if (!failures) std::puts("PAD rumble parity and bounds checks passed");
  return failures ? 1 : 0;
}
