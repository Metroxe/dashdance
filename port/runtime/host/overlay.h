// On-screen controller overlay (touch devices): shapes the renderer draws over the
// presented frame, produced by the host's touch layout each frame.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <vector>

namespace host {
struct OverlayShape {
  float x0, y0, x1, y1;   // window pixels
  float r, g, b, a;       // colour and opacity
  float corner;           // corner radius in pixels (== half extent for circles)
  float ring;             // ring thickness in pixels, 0 = filled
  float pressed;          // 0..1 highlight
  uint32_t label;         // 0 = none, else index into kOverlayLabels
  float label_w, label_h; // label box in pixels (text is fitted inside, aspect kept)
};
constexpr const char* kOverlayLabels[] = {"", "A", "B", "X", "Y", "Z", "L", "R", "Start", "Taunt", "C"};
constexpr int kOverlayLabelCount = (int)(sizeof kOverlayLabels / sizeof kOverlayLabels[0]);
struct OverlayFrame {
  std::vector<OverlayShape> shapes;
  float alpha = 0.0f;     // whole-overlay opacity after fade
};
// Fills `out` with the current overlay; returns false when nothing should be drawn.
bool touch_overlay(OverlayFrame& out);
void touch_set_opacity(float opacity);    // 0..1, user setting
void touch_force_visible(bool visible);   // show even without a touch screen (development)
void haptic_tap(bool strong);             // physical feedback on supported devices
}  // namespace host
