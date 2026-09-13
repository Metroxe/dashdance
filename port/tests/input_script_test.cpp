// SPDX-License-Identifier: GPL-2.0-or-later
#include "input_script.h"
#include <cstdio>
#include <cstdlib>
#include <sstream>

static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
int main() {
  host::InputScript script;
  auto pads = script.sample(0);
  require(pads[0].connected && !pads[1].connected, "neutral port one is connected");
  std::istringstream source("# entry ordering and releases\n2 A+START sx=-80 sy=127\n6 B p=2\n4\n@match\n@loop 8\n0 X+L cx=-128 cy=80\n3 Y p=2\n5\n");
  std::string error;
  require(script.load(source, &error), error.c_str());
  pads = script.sample(1);
  require(pads[0].connected && pads[1].connected && !pads[2].connected && pads[0].buttons == 0, "future scripted ports count as connected");
  pads = script.sample(3);
  require(pads[0].buttons == 0x1100 && pads[0].sx == -80 && pads[0].sy == 127, "absolute button and stick state");
  pads = script.sample(7);
  require(pads[0].buttons == 0 && pads[1].buttons == 0x0200, "per-port release and hold");
  pads = script.sample(10, 10);
  require(pads[0].buttons == 0x0440 && pads[0].cx == -128 && pads[0].cy == 80 && pads[1].buttons == 0, "match origin drops absolute state");
  require(script.sample(13, 10)[1].buttons == 0x0800, "relative port-two state");
  require(script.sample(17, 10)[0].buttons == 0, "relative release");
  require(script.sample(18, 10)[0].buttons == 0x0440, "relative loop wraps");
  for (const char* invalid : {"no-frame A\n", "0 p=5\n", "0 sx=128\n", "0 UNKNOWN\n", "@match extra\n", "4294967296 A\n"}) {
    std::istringstream bad(invalid);
    require(!script.load(bad, &error), "invalid script rejected");
    require(script.sample(18, 10)[0].buttons == 0x0440, "failed script load preserves prior valid state");
  }
}
