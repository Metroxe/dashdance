// Controller configuration shared by the launcher and the game window: per-controller button
// mappings and port assignments, keyed by the controller's stable GUID, persisted in launcher.ini.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace host {
// GameCube controls a physical button can be bound to (index into ControllerMap::binding).
enum GcControl : int { GC_CTL_A, GC_CTL_B, GC_CTL_X, GC_CTL_Y, GC_CTL_Z, GC_CTL_L, GC_CTL_R, GC_CTL_START,
                       GC_CTL_DUP, GC_CTL_DDOWN, GC_CTL_DLEFT, GC_CTL_DRIGHT, GC_CTL_COUNT };
extern const char* const kGcControlNames[GC_CTL_COUNT];
// A physical input: SDL gamepad button ids are 0..N, triggers use kTriggerLeft/kTriggerRight, kUnbound = none.
constexpr int kTriggerLeft = 100, kTriggerRight = 101, kUnbound = -1;
struct ControllerMap {
  int binding[GC_CTL_COUNT];
  bool swap_sticks = false;      // C-stick on the left stick
  static ControllerMap defaults();
  std::string serialize() const;                // "A:0,B:2,..." for launcher.ini
  static ControllerMap parse(const std::string& text);
};
struct ControllerConfig {
  std::string guid;              // SDL GUID string
  int port = 0;                  // 1..4 fixed GameCube port, 0 = first free port in connection order
  ControllerMap map = ControllerMap::defaults();
};
// The configuration table (owned by the host; the window layer reads it on every poll).
const std::vector<ControllerConfig>& controller_configs();
void set_controller_configs(std::vector<ControllerConfig> configs);
const ControllerConfig* controller_config_for(const std::string& guid);
void upsert_controller_config(const ControllerConfig& config);
std::string physical_input_name(int input);   // "A", "Left trigger", ...

// Live controllers, for the launcher UI (requires the gamepad subsystem: window_input_init()).
struct ControllerInfo { std::string name, guid; uint32_t instance_id = 0; int assigned_port = 0; bool is_gamecube_adapter = false; };
void window_input_init();                              // SDL gamepad subsystem without a window
std::vector<ControllerInfo> window_list_controllers();
// Returns the physical input pressed since the previous call on the given controller (kUnbound if none).
int window_capture_input(const std::string& guid);
}  // namespace host
