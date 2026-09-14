// See game_menu.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "game_menu.h"
#include "window.h"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace host {
namespace {
constexpr uint16_t BTN_LEFT = 0x0001, BTN_RIGHT = 0x0002, BTN_DOWN = 0x0004, BTN_UP = 0x0008, BTN_R = 0x0020, BTN_L = 0x0040,
                   BTN_A = 0x0100, BTN_B = 0x0200, BTN_START = 0x1000;
std::mutex g_mutex;
RuntimeSettings g_settings, g_initial;
std::function<void(const RuntimeSettings&, MenuChange)> g_apply;
std::atomic<bool> g_open{false}, g_toggle_request{false}, g_changed{false};
int g_selected = 0;
int g_combo_frames = 0;
uint16_t g_prev_buttons = 0; int g_prev_dir = 0; int g_repeat = 0;
bool g_touch_visible = false;
float g_menu_button[4] = {0, 0, 0, 0};   // MENU touch button rect (window pixels), set by the overlay
struct Layout { float x0, y0, x1, y1, row_h, top; int rows; } g_layout{};   // last drawn panel, for touch hits
int g_open_at_frame = -1;

enum Row { ROW_SCALE, ROW_ANISO, ROW_SHARPEN, ROW_VSYNC, ROW_WIDESCREEN, ROW_VOLUME, ROW_TOUCH_OPACITY, ROW_TOUCH_SIZE, ROW_FULLSCREEN, ROW_HUD, ROW_RESUME, ROW_COUNT };
bool row_visible(int r) {
  if (r == ROW_TOUCH_OPACITY || r == ROW_TOUCH_SIZE) return g_touch_visible;
  if (r == ROW_FULLSCREEN || r == ROW_VSYNC) return !g_touch_visible;   // macOS-only controls
  return true;
}
std::vector<int> visible_rows() { std::vector<int> v; for (int r = 0; r < ROW_COUNT; ++r) if (row_visible(r)) v.push_back(r); return v; }
const char* row_name(int r) {
  switch (r) {
    case ROW_SCALE: return "Internal resolution";
    case ROW_ANISO: return "Anisotropic filtering";
    case ROW_SHARPEN: return "Sharpen";
    case ROW_VSYNC: return "Display sync";
    case ROW_WIDESCREEN: return "Widescreen (next launch)";
    case ROW_VOLUME: return "Volume";
    case ROW_TOUCH_OPACITY: return "Touch controls opacity";
    case ROW_TOUCH_SIZE: return "Touch controls size";
    case ROW_FULLSCREEN: return "Full screen";
    case ROW_HUD: return "Performance HUD";
    case ROW_RESUME: return "Resume game";
  }
  return "";
}
std::string row_value(int r, const RuntimeSettings& s) {
  char b[48];
  switch (r) {
    case ROW_SCALE: if (s.scale == 0) return "Auto"; std::snprintf(b, sizeof b, "%dx", s.scale); return b;
    case ROW_ANISO: return s.anisotropy >= 16 ? "16x" : s.anisotropy >= 4 ? "4x" : "Off";
    case ROW_SHARPEN: std::snprintf(b, sizeof b, "%d%%", (int)std::lround(s.sharpness * 100)); return b;
    case ROW_VSYNC: return s.vsync ? "On" : "Off (lowest latency)";
    case ROW_WIDESCREEN: return s.widescreen ? "16:9" : "4:3";
    case ROW_VOLUME: std::snprintf(b, sizeof b, "%d%%", s.volume); return b;
    case ROW_TOUCH_OPACITY: std::snprintf(b, sizeof b, "%d%%", (int)std::lround(s.overlay_opacity * 100)); return b;
    case ROW_TOUCH_SIZE: std::snprintf(b, sizeof b, "%.2fx", s.overlay_scale); return b;
    case ROW_FULLSCREEN: return s.fullscreen ? "On" : "Off";
    case ROW_HUD: return s.hud ? "On" : "Off";
    case ROW_RESUME: return "";
  }
  return "";
}
// Steps a row's value by `dir` (-1 / +1); returns the change class, or -1 when nothing changed.
int row_step(int r, int dir, RuntimeSettings& s) {
  static const int scales[] = {0, 1, 2, 3, 4, 6, 8};
  switch (r) {
    case ROW_SCALE: { int i = 0; for (int k = 0; k < 7; ++k) if (scales[k] == s.scale) i = k; i = std::clamp(i + dir, 0, 6); s.scale = scales[i]; return (int)MenuChange::Graphics; }
    case ROW_ANISO: { const int a[] = {1, 4, 16}; int i = s.anisotropy >= 16 ? 2 : s.anisotropy >= 4 ? 1 : 0; i = std::clamp(i + dir, 0, 2); s.anisotropy = a[i]; return (int)MenuChange::Graphics; }
    case ROW_SHARPEN: s.sharpness = std::clamp(s.sharpness + 0.1f * dir, 0.0f, 1.0f); return (int)MenuChange::Graphics;
    case ROW_VSYNC: s.vsync = !s.vsync; return (int)MenuChange::Graphics;
    case ROW_WIDESCREEN: s.widescreen = !s.widescreen; return (int)MenuChange::Widescreen;
    case ROW_VOLUME: s.volume = std::clamp(s.volume + 10 * dir, 0, 100); return (int)MenuChange::Volume;
    case ROW_TOUCH_OPACITY: s.overlay_opacity = std::clamp(s.overlay_opacity + 0.1f * dir, 0.1f, 1.0f); return (int)MenuChange::TouchControls;
    case ROW_TOUCH_SIZE: s.overlay_scale = std::clamp(s.overlay_scale + 0.1f * dir, 0.7f, 1.4f); return (int)MenuChange::TouchControls;
    case ROW_FULLSCREEN: s.fullscreen = !s.fullscreen; return (int)MenuChange::Fullscreen;
    case ROW_HUD: s.hud = !s.hud; return (int)MenuChange::Hud;
  }
  return -1;
}
void change(int r, int dir) {
  std::function<void(const RuntimeSettings&, MenuChange)> apply; RuntimeSettings snapshot; int what;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    what = row_step(r, dir, g_settings);
    if (what < 0) return;
    g_changed.store(true); snapshot = g_settings; apply = g_apply;
  }
  if (apply) apply(snapshot, (MenuChange)what);
}
void set_open(bool open) {
  g_open.store(open);
  g_combo_frames = 0; g_repeat = 0; g_prev_dir = 0;
  if (open) { std::lock_guard<std::mutex> lock(g_mutex); const std::vector<int> rows = visible_rows(); if (g_selected >= (int)rows.size()) g_selected = 0; }
}
}  // namespace

void menu_init(const RuntimeSettings& initial, std::function<void(const RuntimeSettings&, MenuChange)> apply) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_settings = g_initial = initial; g_apply = std::move(apply);
  if (const char* e = std::getenv("MELEE_HUD")) g_settings.hud = *e && *e != '0';
  if (const char* e = std::getenv("MELEE_MENU_OPEN")) g_open_at_frame = std::atoi(e);   // screenshot aid: open at this retrace
}
bool menu_is_open() { return g_open.load(); }
bool menu_changed() { return g_changed.load(); }
RuntimeSettings menu_settings() { std::lock_guard<std::mutex> lock(g_mutex); return g_settings; }
void menu_toggle() { g_toggle_request.store(true); }

void menu_frame(PadState pads[4]) {
  if (g_open_at_frame >= 0 && (int)retrace_count() >= g_open_at_frame) { g_open_at_frame = -1; set_open(true); }
  if (g_toggle_request.exchange(false)) set_open(!g_open.load());
  // The open combo: L + R + Start held on any connected controller for half a second.
  bool combo = false;
  for (int i = 0; i < 4; ++i) if (pads[i].err == 0 && (pads[i].button & (BTN_L | BTN_R | BTN_START)) == (BTN_L | BTN_R | BTN_START)) combo = true;
  g_combo_frames = combo ? g_combo_frames + 1 : 0;
  if (g_combo_frames == 30) set_open(!g_open.load());
  if (!g_open.load()) { g_prev_buttons = 0; return; }
  // Navigation from whichever pad is active (the keyboard maps onto port 1's pad).
  uint16_t buttons = 0; int dir_y = 0, dir_x = 0;
  for (int i = 0; i < 4; ++i) {
    if (pads[i].err != 0) continue;
    buttons |= pads[i].button;
    if (pads[i].stick_y > 64 || (pads[i].button & BTN_UP)) dir_y = -1; else if (pads[i].stick_y < -64 || (pads[i].button & BTN_DOWN)) dir_y = 1;
    if (pads[i].stick_x > 64 || (pads[i].button & BTN_RIGHT)) dir_x = 1; else if (pads[i].stick_x < -64 || (pads[i].button & BTN_LEFT)) dir_x = -1;
  }
  const int dir = dir_y ? dir_y * 2 : dir_x;   // one axis at a time; vertical wins
  bool fire = false;
  if (dir != g_prev_dir) { g_repeat = 0; fire = dir != 0; }
  else if (dir != 0 && ++g_repeat >= 20 && (g_repeat - 20) % 6 == 0) fire = true;
  g_prev_dir = dir;
  const std::vector<int> rows = visible_rows();
  if (fire && dir_y) g_selected = (g_selected + dir_y + (int)rows.size()) % (int)rows.size();
  else if (fire && dir_x && !rows.empty()) { const int r = rows[g_selected]; if (r != ROW_RESUME) change(r, dir_x); }
  const uint16_t pressed = buttons & ~g_prev_buttons;
  g_prev_buttons = buttons;
  if (!combo) {
    if ((pressed & BTN_A) && !rows.empty()) { const int r = rows[g_selected]; if (r == ROW_RESUME) set_open(false); else change(r, 1); }
    if (pressed & (BTN_B | BTN_START)) set_open(false);
  }
  // The game sees neutral pads while the menu is up (their connection state is kept).
  for (int i = 0; i < 4; ++i) { const int8_t err = pads[i].err; pads[i] = {}; pads[i].err = err; }
}

bool menu_touch(float px, float py) {
  if (!g_open.load()) {
    if (g_touch_visible && px >= g_menu_button[0] && px <= g_menu_button[2] && py >= g_menu_button[1] && py <= g_menu_button[3]) { set_open(true); return true; }
    return false;
  }
  const Layout l = g_layout;
  if (px < l.x0 || px > l.x1 || py < l.y0 || py > l.y1) { set_open(false); return true; }   // tap outside closes
  const int row = (int)((py - l.top) / std::max(l.row_h, 1.0f));
  const std::vector<int> rows = visible_rows();
  if (row < 0 || row >= (int)rows.size()) return true;
  g_selected = row;
  const int r = rows[row];
  if (r == ROW_RESUME) { set_open(false); return true; }
  const float third = (l.x1 - l.x0) / 3.0f;
  change(r, px < l.x0 + third ? -1 : 1);
  return true;
}

void menu_overlay(OverlayFrame& out, int ww, int wh, bool touch_controls_visible) {
  g_touch_visible = touch_controls_visible;
  RuntimeSettings s; { std::lock_guard<std::mutex> lock(g_mutex); s = g_settings; }
  const float unit = std::clamp(wh / 30.0f, 12.0f, 40.0f);   // line height that suits the window
  // Performance HUD: one line, top-left.
  if (s.hud) {
    GcAdapterStatus adapter; const bool have_adapter = gcadapter_status(adapter);
    char line[200];
    std::snprintf(line, sizeof line, "sim %.1f ms   display %.0f Hz   late %llu%s%s", last_sim_frame_ms(), window_refresh_rate(), (unsigned long long)late_frame_count(),
                  have_adapter ? "   GC adapter " : "", have_adapter ? (adapter.report_hz >= 900 ? "1000 Hz" : adapter.report_hz > 0 ? "125 Hz" : "") : "");
    const float h = unit * 0.7f, pad = h * 0.4f, w = h * 0.55f * (float)std::strlen(line) + pad * 2;
    out.shapes.push_back({pad, pad, pad + w, pad + h + pad * 1.5f, 0.0f, 0.0f, 0.0f, 0.55f, h * 0.35f, 0.0f, 0.0f, 0, 0.0f, 0.0f});
    out.texts.push_back({pad * 2, pad + pad * 0.6f, h, 1, 1, 1, 0.92f, 0, line});
  }
  if (!g_open.load()) {
    if (touch_controls_visible) {   // MENU button, top-right
      const float h = unit * 1.1f, w = h * 2.6f, m = unit * 0.5f;
      g_menu_button[0] = ww - m - w; g_menu_button[1] = m; g_menu_button[2] = ww - m; g_menu_button[3] = m + h;
      out.shapes.push_back({g_menu_button[0], g_menu_button[1], g_menu_button[2], g_menu_button[3], 1, 1, 1, 0.18f, h * 0.5f, 2.0f, 0.0f, 0, 0.0f, 0.0f});
      out.texts.push_back({g_menu_button[0] + w * 0.5f, g_menu_button[1] + h * 0.22f, h * 0.56f, 1, 1, 1, 0.9f, 1, "MENU"});
    }
    return;
  }
  // Dim the game, then the panel.
  out.shapes.push_back({0, 0, (float)ww, (float)wh, 0, 0, 0, 0.55f, 0.0f, 0.0f, 0.0f, 0, 0.0f, 0.0f});
  const std::vector<int> rows = visible_rows();
  const float row_h = unit * 1.45f, pad = unit * 0.9f, title_h = unit * 1.3f;
  const float panel_w = std::min((float)ww - 2 * pad, unit * 24.0f);
  const float panel_h = pad + title_h + unit * 0.5f + row_h * rows.size() + unit * 1.6f + pad;
  const float x0 = (ww - panel_w) * 0.5f, y0 = std::max(pad, (wh - panel_h) * 0.5f), x1 = x0 + panel_w, y1 = y0 + panel_h;
  out.shapes.push_back({x0, y0, x1, y1, 0.03f, 0.04f, 0.12f, 0.985f, unit * 0.7f, 0.0f, 0.0f, 0, 0.0f, 0.0f});
  out.shapes.push_back({x0, y0, x1, y1, 0.5f, 0.6f, 1.0f, 0.25f, unit * 0.7f, 1.5f, 0.0f, 0, 0.0f, 0.0f});
  // Title bar in Melee's angled yellow.
  out.shapes.push_back({x0 + pad, y0 + pad, x0 + pad + panel_w * 0.55f, y0 + pad + title_h, 0.97f, 0.79f, 0.28f, 1.0f, unit * 0.15f, 0.0f, 0.0f, 0, 0.0f, 0.0f});
  out.texts.push_back({x0 + pad + unit * 0.5f, y0 + pad + title_h * 0.12f, title_h * 0.75f, 0.10f, 0.08f, 0.02f, 1.0f, 0, "iSLIPPI  SETTINGS"});
  const float top = y0 + pad + title_h + unit * 0.5f;
  for (size_t i = 0; i < rows.size(); ++i) {
    const int r = rows[i];
    const float ry = top + row_h * i;
    const bool sel = (int)i == g_selected;
    if (sel) out.shapes.push_back({x0 + pad * 0.5f, ry, x1 - pad * 0.5f, ry + row_h, 0.97f, 0.79f, 0.28f, 0.18f, unit * 0.35f, 0.0f, 0.0f, 0, 0.0f, 0.0f});
    const float ty = ry + (row_h - unit) * 0.5f;
    out.texts.push_back({x0 + pad, ty, unit * 0.95f, 1, 1, 1, sel ? 1.0f : 0.85f, 0, row_name(r)});
    const std::string value = row_value(r, s);
    if (!value.empty()) out.texts.push_back({x1 - pad, ty, unit * 0.95f, 0.97f, 0.79f, 0.28f, sel ? 1.0f : 0.8f, 2, (sel && r != ROW_RESUME ? "<  " + value + "  >" : value)});
  }
  out.texts.push_back({(x0 + x1) * 0.5f, y1 - pad - unit * 1.1f, unit * 0.7f, 1, 1, 1, 0.55f, 1,
                       touch_controls_visible ? "Tap a row: left side lowers, right side raises.  Tap outside to resume." : "Up/Down select   Left/Right change   A adjust   B or Start resume   (L+R+Start or F1 opens)"});
  g_layout = {x0, y0, x1, y1, row_h, top, (int)rows.size()};
}
}  // namespace host
