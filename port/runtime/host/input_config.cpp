// SPDX-License-Identifier: GPL-2.0-or-later
#include "input_config.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>

namespace host {
const char* const kGcControlNames[GC_CTL_COUNT] = {"A", "B", "X", "Y", "Z", "L", "R", "Start", "D-pad up", "D-pad down", "D-pad left", "D-pad right"};
namespace {
std::vector<ControllerConfig> g_configs;
// SDL_GamepadButton ids: 0 south, 1 east, 2 west, 3 north, 4 back, 5 guide, 6 start, 7 lstick, 8 rstick,
// 9 lshoulder, 10 rshoulder, 11..14 dpad up/down/left/right.
}  // namespace

ControllerMap ControllerMap::defaults() {
  ControllerMap m;
  const int d[GC_CTL_COUNT] = {0, 2, 1, 3, 10, kTriggerLeft, kTriggerRight, 6, 11, 12, 13, 14};
  std::memcpy(m.binding, d, sizeof d);
  return m;
}
std::string ControllerMap::serialize() const {
  std::ostringstream out;
  for (int i = 0; i < GC_CTL_COUNT; ++i) out << (i ? "," : "") << binding[i];
  out << (swap_sticks ? ",swap" : "");
  return out.str();
}
ControllerMap ControllerMap::parse(const std::string& text) {
  ControllerMap m = defaults();
  std::istringstream in(text);
  std::string token; int i = 0;
  while (std::getline(in, token, ',')) {
    if (token == "swap") { m.swap_sticks = true; continue; }
    if (i < GC_CTL_COUNT) m.binding[i++] = std::atoi(token.c_str());
  }
  return m;
}
const std::vector<ControllerConfig>& controller_configs() { return g_configs; }
void set_controller_configs(std::vector<ControllerConfig> configs) { g_configs = std::move(configs); }
const ControllerConfig* controller_config_for(const std::string& guid) {
  for (const ControllerConfig& c : g_configs) if (c.guid == guid) return &c;
  return nullptr;
}
void upsert_controller_config(const ControllerConfig& config) {
  for (ControllerConfig& c : g_configs) if (c.guid == config.guid) { c = config; return; }
  g_configs.push_back(config);
}
std::string physical_input_name(int input) {
  static const char* const names[] = {"A / Cross", "B / Circle", "X / Square", "Y / Triangle", "Back", "Guide", "Start / Options", "Left stick click", "Right stick click",
                                      "Left shoulder", "Right shoulder", "D-pad up", "D-pad down", "D-pad left", "D-pad right", "Misc 1", "Paddle 1", "Paddle 2", "Paddle 3", "Paddle 4", "Touchpad"};
  if (input == kTriggerLeft) return "Left trigger";
  if (input == kTriggerRight) return "Right trigger";
  if (input >= 0 && input < (int)(sizeof names / sizeof names[0])) return names[input];
  if (input == kUnbound) return "Unbound";
  char buf[32]; std::snprintf(buf, sizeof buf, "Button %d", input); return buf;
}
}  // namespace host
