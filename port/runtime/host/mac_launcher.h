// Native launcher (AppKit on macOS, UIKit on iOS/visionOS): pick the disc, a few
// settings, Play. Nothing from the game ships with the app; the user's own image is used.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>
namespace host {
struct LauncherSettings {
  std::string iso;             // remembered disc image; empty until chosen/imported
  bool widescreen = false;
  float sharpness = 0.0f;      // 0..1
  float overlay_opacity = 1.0f;// on-screen controller (touch devices)
  bool online = true;          // Slippi Online services
  std::string slippi_dir;      // where this app keeps its own user.json (native sign-in)
  std::string account_name, account_code;   // current login, if any
  bool account_from_launcher = false;       // login comes from the Slippi Launcher's file (macOS)
};
// Shows the launcher and blocks until Play (true) or quit (false). `error` explains why the
// remembered disc could not be used, if that happened.
bool launcher_run(LauncherSettings& settings, const std::string& error);
void mac_show_error(const std::string& title, const std::string& detail);
}  // namespace host
