// SPDX-License-Identifier: GPL-2.0-or-later
#include "scene_trace.h"
#include <cstdio>
#include <cstdlib>
static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
int main() {
  host::SceneTrace trace;
  require(trace.observe(1, 0x28, 0), "first observed scene");
  require(!trace.observe(2, 0x28, 0), "unchanged scene is not a transition");
  require(trace.observe(3, 2, 2) && trace.saw(0x0202), "offline in-game byte order");
  require(trace.observe(4, 8, 2) && trace.saw(0x0208), "online in-game byte order");
  require(trace.events()[2].mode_byte == 8 && trace.events()[2].state_byte == 2, "raw bytes remain distinct");
  require(!trace.saw(0x0802), "reversed interpretation was not observed");
  for (uint32_t i = 0; i < 300; ++i) trace.observe(i + 5, uint8_t(i), uint8_t(i >> 8));
  require(trace.size() == 256 && trace.unrecorded() > 0, "timeline storage is bounded");
  require(trace.saw(299) && trace.latest().combined() == 299, "acceptance tracks scenes beyond retained timeline");
}
