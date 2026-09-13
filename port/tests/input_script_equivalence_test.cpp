// Frame-by-frame oracle for the pinned vs_match script.  LegacyScript is the
// original Win32 window.cpp parser/sampler kept independent from InputScript.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "input_script.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {
struct LegacyEntry {
  uint32_t frame;
  uint16_t buttons;
  int8_t sx, sy, cx, cy;
  int port;
  bool relative = false;
};

class LegacyScript {
public:
  bool load(const char* path) {
    FILE* file = std::fopen(path, "r");
    if (!file) return false;
    char line[256];
    while (std::fgets(line, sizeof line, file)) {
      LegacyEntry entry{};
      char* cursor = line;
      if (*cursor == '#' || *cursor == '\n' || *cursor == '\r') continue;
      if (!std::strncmp(cursor, "@match", 6)) { relative_section_ = true; continue; }
      if (!std::strncmp(cursor, "@loop", 5)) {
        loop_ = static_cast<uint32_t>(std::strtoul(cursor + 5, nullptr, 10));
        continue;
      }
      entry.relative = relative_section_;
      entry.frame = static_cast<uint32_t>(std::strtoul(cursor, &cursor, 10));
      while (*cursor) {
        while (*cursor == ' ' || *cursor == '\t') ++cursor;
        if (!*cursor || *cursor == '\n' || *cursor == '\r' || *cursor == '#') break;
        char token[32];
        int length = 0;
        while (*cursor && *cursor != ' ' && *cursor != '+' && *cursor != '\n' &&
               *cursor != '\r' && length < 31) {
          token[length++] = *cursor++;
        }
        token[length] = 0;
        if (*cursor == '+') ++cursor;
        if (!std::strcmp(token, "A")) entry.buttons |= 0x0100;
        else if (!std::strcmp(token, "B")) entry.buttons |= 0x0200;
        else if (!std::strcmp(token, "X")) entry.buttons |= 0x0400;
        else if (!std::strcmp(token, "Y")) entry.buttons |= 0x0800;
        else if (!std::strcmp(token, "Z")) entry.buttons |= 0x0010;
        else if (!std::strcmp(token, "L")) entry.buttons |= 0x0040;
        else if (!std::strcmp(token, "R")) entry.buttons |= 0x0020;
        else if (!std::strcmp(token, "START")) entry.buttons |= 0x1000;
        else if (!std::strcmp(token, "DU")) entry.buttons |= 0x0008;
        else if (!std::strcmp(token, "DD")) entry.buttons |= 0x0004;
        else if (!std::strcmp(token, "DL")) entry.buttons |= 0x0001;
        else if (!std::strcmp(token, "DR")) entry.buttons |= 0x0002;
        else if (!std::strncmp(token, "sx=", 3)) entry.sx = static_cast<int8_t>(std::atoi(token + 3));
        else if (!std::strncmp(token, "sy=", 3)) entry.sy = static_cast<int8_t>(std::atoi(token + 3));
        else if (!std::strncmp(token, "cx=", 3)) entry.cx = static_cast<int8_t>(std::atoi(token + 3));
        else if (!std::strncmp(token, "cy=", 3)) entry.cy = static_cast<int8_t>(std::atoi(token + 3));
        else if (!std::strncmp(token, "p=", 2)) {
          entry.port = std::atoi(token + 2) - 1;
          if (entry.port < 0 || entry.port > 3) entry.port = 0;
          ports_ |= 1u << entry.port;
        }
      }
      entries_.push_back(entry);
    }
    std::fclose(file);
    return !entries_.empty();
  }

  std::array<host::ScriptPad, 4> sample(uint32_t retrace, uint32_t match_start = 0) const {
    std::array<host::ScriptPad, 4> result{};
    bool in_match = match_start && retrace >= match_start;
    uint32_t relative = in_match ? retrace - match_start : 0;
    if (in_match && loop_) relative %= loop_;
    for (int port = 0; port < 4; ++port) {
      if (port && !(ports_ & (1u << port))) continue;
      result[port].connected = true;
      const LegacyEntry* current = nullptr;
      for (const LegacyEntry& entry : entries_) {
        if (entry.port != port) continue;
        if (entry.relative) {
          if (in_match && entry.frame <= relative) current = &entry;
        } else if (!in_match && entry.frame <= retrace) {
          current = &entry;
        }
      }
      if (current) {
        result[port].buttons = current->buttons;
        result[port].sx = current->sx;
        result[port].sy = current->sy;
        result[port].cx = current->cx;
        result[port].cy = current->cy;
      }
    }
    return result;
  }

private:
  std::vector<LegacyEntry> entries_;
  uint32_t ports_ = 1;
  bool relative_section_ = false;
  uint32_t loop_ = 0;
};

[[noreturn]] void fail(const char* message, uint32_t retrace = 0, int port = 0) {
  std::fprintf(stderr, "%s (retrace %u, port %d)\n", message, retrace, port + 1);
  std::exit(1);
}

void require(bool condition, const char* message) {
  if (!condition) fail(message);
}

bool equal(const host::ScriptPad& left, const host::ScriptPad& right) {
  return left.connected == right.connected && left.buttons == right.buttons &&
         left.sx == right.sx && left.sy == right.sy && left.cx == right.cx &&
         left.cy == right.cy;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) fail("usage: input_script_equivalence_test /path/to/vs_match.txt");
  std::ifstream source(argv[1]);
  require(static_cast<bool>(source), "cannot open production script");
  const std::string source_text((std::istreambuf_iterator<char>(source)), std::istreambuf_iterator<char>());
  source.clear();
  source.seekg(0);
  host::InputScript production;
  std::string error;
  require(production.load(source, &error), error.c_str());
  LegacyScript legacy;
  require(legacy.load(argv[1]), "legacy parser cannot open production script");

  for (uint32_t match_start : {0u, 1500u}) {
    for (uint32_t retrace = 0; retrace <= 3000; ++retrace) {
      const auto actual = production.sample(retrace, match_start);
      const auto expected = legacy.sample(retrace, match_start);
      for (int port = 0; port < 4; ++port) {
        if (!equal(actual[port], expected[port])) fail("portable script trace differs from Win32 trace", retrace, port);
      }
    }
  }

  // Fixed trace checkpoints prevent two mutually wrong parsers from agreeing.
  auto pads = production.sample(0);
  require(pads[0].connected && pads[1].connected && !pads[2].connected,
          "a port mentioned later in the file is connected from boot, matching Win32");
  pads = production.sample(300);
  require(pads[0].buttons == 0x0200 && pads[1].buttons == 0, "frame 300 B press");
  require(production.sample(310)[0].buttons == 0, "frame 310 release");
  pads = production.sample(1000);
  require(pads[0].sx == 61 && pads[0].sy == 127 && pads[1].sx == 0 && pads[1].sy == 127,
          "frame 1000 two-port stick state");
  pads = production.sample(1040);
  require(pads[0].buttons == 0x0100 && pads[1].buttons == 0x0100, "frame 1040 two-port A press");
  require(production.sample(1100)[0].buttons == 0x1000, "frame 1100 Start press");
  require(production.sample(1330)[0].buttons == 0x0100, "frame 1330 stage confirm");
  pads = production.sample(2100);
  require(pads[0].buttons == 0 && pads[0].sx == 0 && pads[0].sy == 0,
          "frame 2100 neutral release");
  if (source_text.find("@match") != std::string::npos) {
    pads = production.sample(1530, 1500);
    require(pads[0].sx == 80 && pads[1].sx == -80, "relative frame 30 opposing movement");
    pads = production.sample(1570, 1500);
    require(pads[0].buttons == 0x0100 && pads[1].buttons == 0x0100,
            "relative frame 70 two-port A press");
    pads = production.sample(1605, 1500);
    require(pads[0].buttons == 0x0400 && pads[1].buttons == 0x0800,
            "relative frame 105 distinct jump buttons");
    pads = production.sample(1740, 1500);
    require(pads[0].buttons == 0 && pads[0].sx == 0 && pads[1].buttons == 0 && pads[1].sx == 0,
            "relative loop wraps to frame zero");
  }
  return 0;
}
