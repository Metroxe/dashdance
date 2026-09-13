// SDL3 host: the game window with its CAMetalLayer, events, keyboard and gamepads.
// Works on macOS, iOS and visionOS. Scripted input and the MELEE_PAD_FILE harness
// replace physical devices when present.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "host.h"
#include "input_script.h"
#include "overlay.h"
#include "window.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>

namespace host {
namespace {
enum : uint16_t {
  GC_LEFT = 0x0001, GC_RIGHT = 0x0002, GC_DOWN = 0x0004, GC_UP = 0x0008, GC_Z = 0x0010, GC_R = 0x0020, GC_L = 0x0040,
  GC_A = 0x0100, GC_B = 0x0200, GC_X = 0x0400, GC_Y = 0x0800, GC_START = 0x1000,
};
SDL_Window* g_window = nullptr;
SDL_MetalView g_view = nullptr;
ResizeCallback g_resize;
MessageCallback g_message;
std::atomic<bool> g_closed{false};
std::atomic<bool> g_fullscreen_toggle{false};
std::atomic<bool> g_capture{false};
std::mutex g_ui_mutex;
PadState g_ui_pad{};
bool g_ui_gamecube = false;
int g_client_w = 0, g_client_h = 0;
std::vector<SDL_Gamepad*> g_gamepads;
int g_gamepad_port[4] = {-1, -1, -1, -1};   // GameCube port -> index into g_gamepads (set by input_poll)
InputScript g_script;
bool g_scripted = false;
std::atomic<uint32_t> g_match_start{0};

// Touch controls (iPhone, iPad, Apple Vision Pro). Layout and touch model follow
// VirtualFriend's on-screen controller (Adam Gastineau, MIT): two side columns of
// translucent monochrome shapes (trigger capsule, pad, two round buttons), every
// finger is tested against every button on each touch event so presses slide
// naturally between buttons. Adapted to a GameCube pad: analog stick on the left,
// the A/B/X/Y cluster on the right, Z and the C-stick below it.
enum Label : uint32_t { LB_NONE, LB_A, LB_B, LB_X, LB_Y, LB_Z, LB_L, LB_R, LB_START, LB_TAUNT, LB_C };   // kOverlayLabels order
static_assert(LB_C + 1 == kOverlayLabelCount, "Label enum must match kOverlayLabels");
struct Rect { float x0, y0, x1, y1; bool contains(float x, float y) const { return x >= x0 && x < x1 && y >= y0 && y < y1; } };
struct TouchButton {
  uint16_t button; bool trigger_l, trigger_r; uint32_t label; Rect rect; bool capsule; bool pressed;
  bool hit(float x, float y) const {   // capsules by their box, round buttons by their inscribed circle
    if (capsule) return rect.contains(x, y);
    const float cx = (rect.x0 + rect.x1) * 0.5f, cy = (rect.y0 + rect.y1) * 0.5f, r = (rect.x1 - rect.x0) * 0.5f;
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
  }
};
struct TouchStick { Rect rect; float radius; SDL_FingerID finger; bool owned, active; float dx, dy; bool c; };
struct TouchLayout { std::vector<TouchButton> buttons; TouchStick stick{}, cstick{}; int w = 0, h = 0; float pt = 1.0f; };
TouchLayout g_touch;
struct Finger { SDL_FingerID id; float x, y; };
std::vector<Finger> g_fingers;
bool g_touch_seen = false, g_touch_forced = false;
float g_touch_opacity = 1.0f, g_touch_alpha = 0.0f, g_pixels_per_point = 1.0f;
std::mutex g_touch_mutex;   // events arrive on the main thread; input_poll and the overlay run on others

Rect circle(float cx, float cy, float r) { return {cx - r, cy - r, cx + r, cy + r}; }
void touch_layout() {
  TouchLayout& t = g_touch;
  if (t.w == g_client_w && t.h == g_client_h && t.pt == g_pixels_per_point && !t.buttons.empty()) return;
  t.w = g_client_w; t.h = g_client_h; t.pt = g_pixels_per_point;
  std::vector<bool> pressed;
  for (const TouchButton& b : t.buttons) pressed.push_back(b.pressed);
  t.buttons.clear();
  const float pad = 24.0f * t.pt, W = (float)t.w, H_full = (float)t.h;
  // Portrait (iPhone, iPad held upright): the game sits at the top, the controls fill the rest.
  const bool portrait = H_full > W * 1.05f;
  const float top = portrait ? W * 0.75f : 0.0f, H = H_full - top;
  const float col_h = H - 2 * pad;
  const float col_w = portrait ? std::min(W * 0.42f, 320.0f * t.pt) : std::min(std::max(200.0f * t.pt, H * 0.36f), W * 0.28f);
  const float trig_h = col_h * 0.13f, mid = std::min(col_w, col_h * 0.60f), row_h = col_h * 0.27f;
  const float gap = 16.0f * t.pt, btn_d = std::min(row_h, col_w * 0.42f);
  auto column = [&](float x0, bool left) {
    const float cx = x0 + col_w * 0.5f;
    const float y_trig = top + pad, y_mid = y_trig + trig_h + gap, y_row = y_trig + trig_h + col_h * 0.60f + (row_h - btn_d) * 0.5f;
    const float mid_d = mid - 2 * gap;
    if (left) {
      t.buttons.push_back({GC_L, true, false, LB_L, {x0, y_trig, x0 + col_w, y_trig + trig_h}, true, false});
      t.stick.rect = circle(cx, y_mid + mid_d * 0.5f, mid_d * 0.5f); t.stick.radius = mid_d * 0.5f; t.stick.c = false;
      t.buttons.push_back({GC_START, false, false, LB_START, circle(x0 + btn_d * 0.5f, y_row + btn_d * 0.5f, btn_d * 0.5f), false, false});
      t.buttons.push_back({GC_UP, false, false, LB_TAUNT, circle(x0 + col_w - btn_d * 0.5f, y_row + btn_d * 0.5f, btn_d * 0.5f), false, false});
    } else {
      t.buttons.push_back({GC_R, false, true, LB_R, {x0, y_trig, x0 + col_w, y_trig + trig_h}, true, false});
      // GameCube face cluster inside the middle square: big A, B low-left, X right, Y above.
      const float sx = cx - mid_d * 0.5f, sy = y_mid;
      t.buttons.push_back({GC_A, false, false, LB_A, circle(sx + mid_d * 0.56f, sy + mid_d * 0.62f, mid_d * 0.25f), false, false});
      t.buttons.push_back({GC_B, false, false, LB_B, circle(sx + mid_d * 0.15f, sy + mid_d * 0.82f, mid_d * 0.14f), false, false});
      t.buttons.push_back({GC_X, false, false, LB_X, circle(sx + mid_d * 0.88f, sy + mid_d * 0.34f, mid_d * 0.14f), false, false});
      t.buttons.push_back({GC_Y, false, false, LB_Y, circle(sx + mid_d * 0.44f, sy + mid_d * 0.14f, mid_d * 0.14f), false, false});
      t.buttons.push_back({GC_Z, false, false, LB_Z, circle(x0 + btn_d * 0.5f, y_row + btn_d * 0.5f, btn_d * 0.5f), false, false});
      t.cstick.rect = circle(x0 + col_w - btn_d * 0.5f, y_row + btn_d * 0.5f, btn_d * 0.5f); t.cstick.radius = btn_d * 0.5f; t.cstick.c = true;
    }
  };
  column(pad, true);
  column(W - pad - col_w, false);
  for (size_t i = 0; i < t.buttons.size() && i < pressed.size(); ++i) t.buttons[i].pressed = pressed[i];
}
bool physical_gamepad_connected() {
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
  return false;   // the Simulator always exposes a virtual Apple "Gamepad"
#else
  return !g_gamepads.empty();
#endif
}
bool touch_controls_visible() { return (g_touch_seen || g_touch_forced) && !physical_gamepad_connected() && g_touch_opacity > 0.0f; }

void stick_update(TouchStick& st) {
  st.active = false;
  if (!st.owned) return;
  for (const Finger& f : g_fingers) {
    if (f.id != st.finger) continue;
    const float cx = (st.rect.x0 + st.rect.x1) * 0.5f, cy = (st.rect.y0 + st.rect.y1) * 0.5f;
    const float lim = st.radius * 0.72f;   // full deflection well inside the track
    float dx = f.x - cx, dy = f.y - cy;
    const float len = std::sqrt(dx * dx + dy * dy);
    if (len > lim) { dx *= lim / len; dy *= lim / len; }
    st.dx = dx / lim; st.dy = dy / lim; st.active = true;
  }
}
void touch_reevaluate() {
  touch_layout();
  for (TouchButton& b : g_touch.buttons) {
    bool pressed = false;
    for (const Finger& f : g_fingers) if (b.hit(f.x, f.y)) pressed = true;
    if (pressed && !b.pressed) haptic_tap(b.button == GC_A);
    b.pressed = pressed;
  }
  stick_update(g_touch.stick);
  stick_update(g_touch.cstick);
}
void touch_event(const SDL_TouchFingerEvent& e) {
  std::lock_guard<std::mutex> lock(g_touch_mutex);
  g_touch_seen = true;
  touch_layout();
  const float px = e.x * (float)g_client_w, py = e.y * (float)g_client_h;
  if (e.type == SDL_EVENT_FINGER_DOWN) {
    g_fingers.push_back({e.fingerID, px, py});
    // A finger that lands on a stick owns it until it lifts, even when it wanders off.
    for (TouchStick* st : {&g_touch.stick, &g_touch.cstick})
      if (!st->owned && st->rect.contains(px, py)) { st->finger = e.fingerID; st->owned = true; haptic_tap(false); break; }
  } else if (e.type == SDL_EVENT_FINGER_MOTION) {
    for (Finger& f : g_fingers) if (f.id == e.fingerID) { f.x = px; f.y = py; }
  } else {
    for (auto it = g_fingers.begin(); it != g_fingers.end();) { if (it->id == e.fingerID) it = g_fingers.erase(it); else ++it; }
    for (TouchStick* st : {&g_touch.stick, &g_touch.cstick}) if (st->owned && st->finger == e.fingerID) st->owned = false;
  }
  touch_reevaluate();
}

void read_touch(PadState& p) {
  std::lock_guard<std::mutex> lock(g_touch_mutex);
  if (!g_touch_seen) return;
  if (!touch_controls_visible()) {   // a gamepad took over: drop any latched touch state
    g_fingers.clear();
    g_touch.stick.owned = g_touch.stick.active = g_touch.cstick.owned = g_touch.cstick.active = false;
    for (TouchButton& b : g_touch.buttons) b.pressed = false;
    return;
  }
  p.err = 0;
  if (g_touch.stick.active) {
    p.stick_x = (int8_t)std::clamp((int)std::lround(g_touch.stick.dx * 127.0f), -127, 127);
    p.stick_y = (int8_t)std::clamp((int)std::lround(-g_touch.stick.dy * 127.0f), -127, 127);
  }
  if (g_touch.cstick.active) {
    p.sub_x = (int8_t)std::clamp((int)std::lround(g_touch.cstick.dx * 127.0f), -127, 127);
    p.sub_y = (int8_t)std::clamp((int)std::lround(-g_touch.cstick.dy * 127.0f), -127, 127);
  }
  for (const TouchButton& b : g_touch.buttons) {
    if (!b.pressed) continue;
    p.button |= b.button;
    if (b.trigger_l) p.trig_l = 255;
    if (b.trigger_r) p.trig_r = 255;
  }
}
}  // namespace

bool touch_overlay(OverlayFrame& out) {
  std::lock_guard<std::mutex> lock(g_touch_mutex);
  const float target = touch_controls_visible() ? g_touch_opacity : 0.0f;
  g_touch_alpha += std::clamp(target - g_touch_alpha, -0.08f, 0.08f);
  out.shapes.clear();
  out.alpha = g_touch_alpha;
  if (g_touch_alpha <= 0.001f) return false;
  touch_layout();
  // VirtualFriend's palette on a dark background: buttons white 0.4 at 50%, touched white 0.6 at 50%.
  const float base = 0.40f, touched = 0.60f, alpha = 0.50f;
  for (const TouchButton& b : g_touch.buttons) {
    const float shade = b.pressed ? touched : base;
    const float h = b.rect.y1 - b.rect.y0, w = b.rect.x1 - b.rect.x0;
    const float label_h = b.capsule ? h * 0.62f : h * 0.34f;
    out.shapes.push_back({b.rect.x0, b.rect.y0, b.rect.x1, b.rect.y1, shade, shade, shade, alpha, b.capsule ? h * 0.5f : w * 0.5f, 0.0f, b.pressed ? 1.0f : 0.0f, b.label, w * 0.8f, label_h});
  }
  for (const TouchStick* st : {&g_touch.stick, &g_touch.cstick}) {
    const float cx = (st->rect.x0 + st->rect.x1) * 0.5f, cy = (st->rect.y0 + st->rect.y1) * 0.5f;
    out.shapes.push_back({st->rect.x0, st->rect.y0, st->rect.x1, st->rect.y1, base, base, base, alpha, st->radius, 0.0f, 0.0f, (uint32_t)LB_NONE, 0.0f, 0.0f});
    const float kr = st->radius * (st->c ? 0.42f : 0.36f), lim = st->radius * 0.72f;
    const float kx = cx + (st->active ? st->dx * lim : 0.0f), ky = cy + (st->active ? st->dy * lim : 0.0f);
    const float shade = st->active ? touched + 0.15f : touched;
    out.shapes.push_back({kx - kr, ky - kr, kx + kr, ky + kr, shade, shade, shade, alpha + 0.2f, kr, 0.0f, st->active ? 1.0f : 0.0f, st->c ? (uint32_t)LB_C : (uint32_t)LB_NONE, kr * 1.2f, kr * 0.9f});
  }
  return true;
}
void touch_set_opacity(float opacity) { std::lock_guard<std::mutex> lock(g_touch_mutex); g_touch_opacity = std::clamp(opacity, 0.0f, 1.0f); }
void touch_force_visible(bool visible) { std::lock_guard<std::mutex> lock(g_touch_mutex); g_touch_forced = visible; }

namespace {
std::string narrow(const wchar_t* text) {
  std::string out;
  for (; text && *text; ++text) {
    const uint32_t c = (uint32_t)*text;
    if (c < 0x80) out += (char)c;
    else if (c < 0x800) { out += (char)(0xC0 | (c >> 6)); out += (char)(0x80 | (c & 0x3F)); }
    else if (c < 0x10000) { out += (char)(0xE0 | (c >> 12)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
    else { out += (char)(0xF0 | (c >> 18)); out += (char)(0x80 | ((c >> 12) & 0x3F)); out += (char)(0x80 | ((c >> 6) & 0x3F)); out += (char)(0x80 | (c & 0x3F)); }
  }
  return out;
}

void refresh_client_size() {
  if (!g_window) return;
  int w = 0, h = 0;
  SDL_GetWindowSizeInPixels(g_window, &w, &h);
  int pw = 0, ph = 0;
  SDL_GetWindowSize(g_window, &pw, &ph);
  std::lock_guard<std::mutex> lock(g_touch_mutex);   // the touch layout reads these from other threads
  g_client_w = std::max(w, 1); g_client_h = std::max(h, 1);
  g_pixels_per_point = pw > 0 ? (float)g_client_w / (float)pw : 1.0f;
}

void open_gamepad(SDL_JoystickID id) {
  if (SDL_Gamepad* pad = SDL_OpenGamepad(id)) {
    g_gamepads.push_back(pad);
    log("input: gamepad connected: %s (vendor %04x product %04x)", SDL_GetGamepadName(pad), SDL_GetGamepadVendor(pad), SDL_GetGamepadProduct(pad));
  }
}
void close_gamepad(SDL_JoystickID id) {
  for (auto it = g_gamepads.begin(); it != g_gamepads.end(); ++it) {
    if (SDL_GetGamepadID(*it) == id) { SDL_CloseGamepad(*it); g_gamepads.erase(it); log("input: gamepad disconnected"); return; }
  }
}

int8_t axis_to_stick(Sint16 v, int deadzone) {
  if (v > -deadzone && v < deadzone) return 0;
  int a = v / 258;
  return (int8_t)(a > 127 ? 127 : a < -127 ? -127 : a);
}

// Xbox/PlayStation-layout gamepads mapped the way Dolphin's default profile does.
void read_gamepad(SDL_Gamepad* pad, PadState& p) {
  p.err = 0;
  auto btn = [&](SDL_GamepadButton b) { return SDL_GetGamepadButton(pad, b); };
  if (btn(SDL_GAMEPAD_BUTTON_SOUTH)) p.button |= GC_A;
  if (btn(SDL_GAMEPAD_BUTTON_WEST)) p.button |= GC_B;
  if (btn(SDL_GAMEPAD_BUTTON_EAST)) p.button |= GC_X;
  if (btn(SDL_GAMEPAD_BUTTON_NORTH)) p.button |= GC_Y;
  if (btn(SDL_GAMEPAD_BUTTON_START)) p.button |= GC_START;
  if (btn(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)) p.button |= GC_Z;
  if (btn(SDL_GAMEPAD_BUTTON_DPAD_UP)) p.button |= GC_UP;
  if (btn(SDL_GAMEPAD_BUTTON_DPAD_DOWN)) p.button |= GC_DOWN;
  if (btn(SDL_GAMEPAD_BUTTON_DPAD_LEFT)) p.button |= GC_LEFT;
  if (btn(SDL_GAMEPAD_BUTTON_DPAD_RIGHT)) p.button |= GC_RIGHT;
  const Sint16 lx = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX), ly = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY);
  const Sint16 rx = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTX), ry = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY);
  if (std::abs(lx) > 7849 || std::abs(ly) > 7849) { p.stick_x = axis_to_stick(lx, 0); p.stick_y = axis_to_stick((Sint16)-ly, 0); }
  if (std::abs(rx) > 8689 || std::abs(ry) > 8689) { p.sub_x = axis_to_stick(rx, 0); p.sub_y = axis_to_stick((Sint16)-ry, 0); }
  const int lt = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 129, rt = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 129;
  if (lt > 30) { p.trig_l = (uint8_t)std::min(lt, 255); if (lt > 200) p.button |= GC_L; }
  if (rt > 30) { p.trig_r = (uint8_t)std::min(rt, 255); if (rt > 200) p.button |= GC_R; }
  if (btn(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)) { p.button |= GC_L; p.trig_l = 255; }
}

void read_keyboard(PadState& p) {
  int count = 0;
  const bool* keys = SDL_GetKeyboardState(&count);
  if (!keys) return;
  auto key = [&](SDL_Scancode code) { return code < count && keys[code]; };
  int sx = 0, sy = 0, cx = 0, cy = 0;
  if (key(SDL_SCANCODE_LEFT)) sx -= 127; if (key(SDL_SCANCODE_RIGHT)) sx += 127;
  if (key(SDL_SCANCODE_UP)) sy += 127; if (key(SDL_SCANCODE_DOWN)) sy -= 127;
  if (key(SDL_SCANCODE_J)) cx -= 127; if (key(SDL_SCANCODE_L)) cx += 127;
  if (key(SDL_SCANCODE_I)) cy += 127; if (key(SDL_SCANCODE_K)) cy -= 127;
  if (key(SDL_SCANCODE_Z)) p.button |= GC_A; if (key(SDL_SCANCODE_X)) p.button |= GC_B;
  if (key(SDL_SCANCODE_C)) p.button |= GC_X; if (key(SDL_SCANCODE_V)) p.button |= GC_Y;
  if (key(SDL_SCANCODE_RETURN) || key(SDL_SCANCODE_KP_ENTER)) p.button |= GC_START;
  if (key(SDL_SCANCODE_Q)) { p.button |= GC_L; p.trig_l = 255; }
  if (key(SDL_SCANCODE_W)) { p.button |= GC_R; p.trig_r = 255; }
  if (key(SDL_SCANCODE_E)) p.button |= GC_Z;
  if (key(SDL_SCANCODE_T)) p.button |= GC_UP; if (key(SDL_SCANCODE_G)) p.button |= GC_DOWN;
  if (key(SDL_SCANCODE_F)) p.button |= GC_LEFT; if (key(SDL_SCANCODE_H)) p.button |= GC_RIGHT;
  if (sx || sy) { p.stick_x = (int8_t)sx; p.stick_y = (int8_t)sy; }
  if (cx || cy) { p.sub_x = (int8_t)cx; p.sub_y = (int8_t)cy; }
}

// Development aid: MELEE_PAD_FILE names a text file re-read every poll. Each line is
// "[p=N] BUTTON+BUTTON [sx=N] [sy=N] [cx=N] [cy=N]"; the state holds until the file changes.
bool pad_file(PadState out[4]) {
  static const char* path = std::getenv("MELEE_PAD_FILE");
  if (!path) return false;
  std::ifstream file(path);
  if (!file) return false;
  bool any = false;
  std::string line;
  while (std::getline(file, line)) {
    if (line.empty() || line[0] == '#') continue;
    int port = 0;
    PadState p{};
    size_t pos = 0;
    while (pos < line.size()) {
      while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t' || line[pos] == '+')) ++pos;
      size_t end = pos;
      while (end < line.size() && line[end] != ' ' && line[end] != '\t' && line[end] != '+') ++end;
      if (end == pos) break;
      const std::string tok = line.substr(pos, end - pos);
      pos = end;
      if (tok == "A") p.button |= GC_A; else if (tok == "B") p.button |= GC_B;
      else if (tok == "X") p.button |= GC_X; else if (tok == "Y") p.button |= GC_Y;
      else if (tok == "Z") p.button |= GC_Z; else if (tok == "L") { p.button |= GC_L; p.trig_l = 255; }
      else if (tok == "R") { p.button |= GC_R; p.trig_r = 255; } else if (tok == "START") p.button |= GC_START;
      else if (tok == "DU") p.button |= GC_UP; else if (tok == "DD") p.button |= GC_DOWN;
      else if (tok == "DL") p.button |= GC_LEFT; else if (tok == "DR") p.button |= GC_RIGHT;
      else if (tok.rfind("sx=", 0) == 0) p.stick_x = (int8_t)std::atoi(tok.c_str() + 3);
      else if (tok.rfind("sy=", 0) == 0) p.stick_y = (int8_t)std::atoi(tok.c_str() + 3);
      else if (tok.rfind("cx=", 0) == 0) p.sub_x = (int8_t)std::atoi(tok.c_str() + 3);
      else if (tok.rfind("cy=", 0) == 0) p.sub_y = (int8_t)std::atoi(tok.c_str() + 3);
      else if (tok.rfind("p=", 0) == 0) { port = std::atoi(tok.c_str() + 2) - 1; if (port < 0 || port > 3) port = 0; }
    }
    p.err = 0;
    out[port] = p;
    any = true;
  }
  if (!any) out[0].err = 0;
  return true;
}
}  // namespace

void* window_create(int w, int h, const wchar_t* title, bool visible) {
  if (!SDL_InitSubSystem(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_GAMEPAD)) die("SDL: %s", SDL_GetError());
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");   // hidden, and the first swipe only shows it
  Uint32 flags = SDL_WINDOW_METAL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
  if (!visible) flags |= SDL_WINDOW_HIDDEN;
#if defined(__APPLE__) && !TARGET_OS_OSX
  flags |= SDL_WINDOW_FULLSCREEN;
  g_touch_seen = true;   // touch devices show the on-screen controller until a gamepad connects
#endif
  if (const char* force = std::getenv("MELEE_TOUCH_OVERLAY")) g_touch_forced = *force && *force != '0';
  g_window = SDL_CreateWindow(narrow(title).c_str(), w, h, flags);
  if (!g_window) die("SDL window: %s", SDL_GetError());
  g_view = SDL_Metal_CreateView(g_window);
  if (!g_view) die("SDL Metal view: %s", SDL_GetError());
  refresh_client_size();
  int count = 0;
  if (SDL_JoystickID* ids = SDL_GetGamepads(&count)) {
    for (int i = 0; i < count; ++i) open_gamepad(ids[i]);
    SDL_free(ids);
  }
  return SDL_Metal_GetLayer(g_view);
}

void window_set_message_callback(MessageCallback cb) { g_message = std::move(cb); }
void window_input_capture(bool capture) { g_capture.store(capture); }
bool window_ui_gamecube_pad(PadState& pad) { std::lock_guard<std::mutex> lock(g_ui_mutex); pad = g_ui_pad; return g_ui_gamecube; }
void window_set_resize_callback(ResizeCallback cb) { g_resize = std::move(cb); }

void window_pump() {
  if (!g_window) return;
  SDL_Event event;
  bool resized = false;
  while (SDL_PollEvent(&event)) {
    switch (event.type) {
      case SDL_EVENT_QUIT: case SDL_EVENT_WINDOW_CLOSE_REQUESTED: g_closed.store(true); request_exit(0); break;
      case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: case SDL_EVENT_WINDOW_RESIZED: resized = true; break;
      case SDL_EVENT_GAMEPAD_ADDED: open_gamepad(event.gdevice.which); break;
      case SDL_EVENT_GAMEPAD_REMOVED: close_gamepad(event.gdevice.which); break;
      case SDL_EVENT_KEY_DOWN:
        if (event.key.key == SDLK_RETURN && (event.key.mod & SDL_KMOD_ALT) && !event.key.repeat) g_fullscreen_toggle.store(true);
        break;
      case SDL_EVENT_FINGER_DOWN: case SDL_EVENT_FINGER_MOTION: case SDL_EVENT_FINGER_UP: case SDL_EVENT_FINGER_CANCELED:
        touch_event(event.tfinger);
        break;
      default: break;
    }
  }
  if (resized) {
    refresh_client_size();
    if (g_resize) g_resize(g_client_w, g_client_h);
  }
}

void window_set_fullscreen(bool enabled) { if (g_window) SDL_SetWindowFullscreen(g_window, enabled); }
// Rumble for a GameCube port served by an SDL gamepad (DualSense, Xbox, MFi, Switch Pro...).
void window_gamepad_rumble(int port, bool on) {
  if (port < 0 || port >= 4) return;
  const int index = g_gamepad_port[port];
  if (index < 0 || index >= (int)g_gamepads.size()) return;
  SDL_RumbleGamepad(g_gamepads[(size_t)index], on ? 0xC000 : 0, on ? 0xC000 : 0, on ? 250 : 0);
}
bool window_take_fullscreen_toggle() { return g_fullscreen_toggle.exchange(false); }
double window_refresh_rate() {
  if (!g_window) return 60.0;
  const SDL_DisplayMode* mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(g_window));
  return mode && mode->refresh_rate > 0 ? mode->refresh_rate : 60.0;
}
void window_destroy() {
  for (SDL_Gamepad* pad : g_gamepads) SDL_CloseGamepad(pad);
  g_gamepads.clear();
  if (g_view) { SDL_Metal_DestroyView(g_view); g_view = nullptr; }
  if (g_window) { SDL_DestroyWindow(g_window); g_window = nullptr; }
}
void window_set_title(const wchar_t* title) { if (g_window) SDL_SetWindowTitle(g_window, narrow(title).c_str()); }
bool window_closed() { return g_closed.load(); }
void window_client_size(int* w, int* h) { if (w) *w = g_client_w; if (h) *h = g_client_h; }

bool input_load_script(const char* path) {
  std::ifstream file(path);
  if (!file) return false;
  std::string error;
  if (!g_script.load(file, &error)) { std::fprintf(stderr, "input script: %s\n", error.c_str()); return false; }
  g_scripted = true;
  return true;
}
void input_mark_match_start() { g_match_start.store(retrace_count()); }

void input_poll(PadState out[4]) {
  struct UiSnapshot {
    PadState* pads; bool gamecube = false;
    ~UiSnapshot() {
      std::lock_guard<std::mutex> lock(g_ui_mutex); g_ui_pad = pads[0]; g_ui_gamecube = gamecube;
      if (g_capture.load()) { pads[0] = {}; pads[0].err = 0; }
    }
  } ui{out};
  for (int i = 0; i < 4; ++i) { out[i] = {}; out[i].err = -1; }
  if (pad_file(out)) return;
  if (g_scripted) {
    auto pads = g_script.sample(retrace_count(), g_match_start.load());
    for (unsigned port = 0; port < pads.size(); ++port) {
      out[port].err = pads[port].connected ? 0 : -1;
      out[port].button = pads[port].buttons;
      out[port].stick_x = pads[port].sx; out[port].stick_y = pads[port].sy;
      out[port].sub_x = pads[port].cx; out[port].sub_y = pads[port].cy;
    }
    return;
  }
  const uint32_t adapter_mask = gcadapter_poll(out);
  ui.gamecube = (adapter_mask & 1u) != 0;
  // Gamepads fill ports in connection order after the adapter's; the keyboard adds to port 1.
  int port = 0;
  for (int i = 0; i < 4; ++i) g_gamepad_port[i] = -1;
  for (size_t index = 0; index < g_gamepads.size(); ++index) {
    while (port < 4 && (adapter_mask & (1u << port))) ++port;
    if (port >= 4) break;
    read_gamepad(g_gamepads[index], out[port]);
    g_gamepad_port[port] = (int)index;
    ++port;
  }
  if (!(adapter_mask & 1u)) { out[0].err = 0; read_keyboard(out[0]); read_touch(out[0]); }
}
}  // namespace host
