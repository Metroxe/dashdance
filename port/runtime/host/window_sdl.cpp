// SDL3 host: the game window with its CAMetalLayer, events, keyboard and gamepads.
// Works on macOS, iOS and visionOS. Scripted input and the MELEE_PAD_FILE harness
// replace physical devices when present.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "host.h"
#include "input_script.h"
#include "window.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#include <atomic>
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
InputScript g_script;
bool g_scripted = false;
std::atomic<uint32_t> g_match_start{0};

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
  g_client_w = std::max(w, 1); g_client_h = std::max(h, 1);
}

void open_gamepad(SDL_JoystickID id) {
  if (SDL_Gamepad* pad = SDL_OpenGamepad(id)) {
    g_gamepads.push_back(pad);
    log("input: gamepad connected: %s", SDL_GetGamepadName(pad));
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
  Uint32 flags = SDL_WINDOW_METAL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
  if (!visible) flags |= SDL_WINDOW_HIDDEN;
#if defined(__APPLE__) && !TARGET_OS_OSX
  flags |= SDL_WINDOW_FULLSCREEN;
#endif
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
      default: break;
    }
  }
  if (resized) {
    refresh_client_size();
    if (g_resize) g_resize(g_client_w, g_client_h);
  }
}

void window_set_fullscreen(bool enabled) { if (g_window) SDL_SetWindowFullscreen(g_window, enabled); }
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
  for (SDL_Gamepad* pad : g_gamepads) {
    while (port < 4 && (adapter_mask & (1u << port))) ++port;
    if (port >= 4) break;
    read_gamepad(pad, out[port]);
    ++port;
  }
  if (!(adapter_mask & 1u)) { out[0].err = 0; read_keyboard(out[0]); }
}
}  // namespace host
