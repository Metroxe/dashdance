// Cocoa helpers for the macOS application: disc picker and error alerts.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>
namespace host {
// Shows a native open panel; returns an empty string when the user cancels.
std::string mac_choose_disc(const std::string& previous_error);
void mac_show_error(const std::string& title, const std::string& detail);
}  // namespace host
