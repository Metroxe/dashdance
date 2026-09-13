// Deterministic controller script state, independent of the window or CPU backend.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstdint>
#include <istream>
#include <string>
#include <vector>

namespace host {
struct ScriptPad {
  uint16_t buttons = 0;
  int8_t sx = 0, sy = 0, cx = 0, cy = 0;
  bool connected = false;
};
class InputScript {
public:
  bool load(std::istream& stream, std::string* error = nullptr);
  std::array<ScriptPad, 4> sample(uint32_t retrace, uint32_t match_start = 0) const;
  bool empty() const { return entries_.empty(); }
private:
  struct Entry {
    uint32_t frame = 0;
    ScriptPad pad;
    unsigned port = 0;
    bool relative = false;
  };
  std::vector<Entry> entries_;
  uint32_t ports_ = 1;
  uint32_t loop_ = 0;
};
}  // namespace host
