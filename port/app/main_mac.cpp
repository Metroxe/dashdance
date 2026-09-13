// macOS entry point: Aurora Cocoa/Metal window, SDL3 audio device, keyboard and
// SDL gamepads, and the Slippi Online services (matchmaking, netplay, reporting).
// SPDX-License-Identifier: GPL-2.0-or-later
#include "audio.h"
#include "exi_slippi.h"
#include "gecko_data.h"
#include "gx_core.h"
#include "gx_metal.h"
#include "overlay.h"
#include "hle_dvd.h"
#include "host.h"
#include "mac_launcher.h"
#include "numeric.h"
#include "slippi_net.h"
#include "slippi_online.h"
#include "window.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <algorithm>
#include <mach-o/dyld.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <SDL3/SDL_main.h>
#endif

#ifndef MELEE_PORT_VERSION
#define MELEE_PORT_VERSION "dev"
#endif

namespace ppc { void init_dispatch(); }
namespace fs = std::filesystem;

namespace {
void usage() {
  std::printf(
      "melee_port_mac --iso <Melee NTSC 1.02 image> [options]\n"
      "  --choose-disc            always show the disc picker\n"
      "  --volume 0-100           output volume (default 70)\n"
      "  --window WxH             initial window size (default 1280x960)\n"
      "  --no-vsync               present without vertical sync\n"
      "  --scale N|auto           internal resolution multiplier (default auto)\n"
      "  --widescreen             Slippi 16:9 code and 16:9 presentation\n"
      "  --sharpness 0..1         contrast-adaptive sharpening\n"
      "  --touch-overlay          show the on-screen controller (default on touch devices)\n"
      "  --overlay-opacity 0..1   on-screen controller opacity\n"
      "  --anisotropy 1..16       anisotropic filtering (default 16)\n"
      "  --capture FILE.ppm       write the presented frame N (--capture-frame N)\n"
      "  --offline                disable Slippi Online services\n"
      "  --user-dir DIR           Slippi folder holding user.json (default: the Slippi Launcher's)\n"
      "  --online-delay N         Slippi Online input delay frames (default 2)\n"
      "  --chat on|direct|off     in-game chat availability\n"
      "  --netplay-port N         fixed local UDP port for netplay\n"
      "  --local-peer i:port:ip:port  peer two local instances directly (testing)\n"
      "  --sys-dir DIR            Slippi Sys folder (code tables, GameFiles)\n"
      "  --replay-dir DIR         .slp output (default ~/Library/Application Support/MeleeUnlocked/Replays)\n"
      "  --card-dir DIR           memory card A folder of .gci files\n"
      "  --profile-dir DIR        app profile root (settings, Aurora preferences)\n"
      "  --cache-dir DIR          pipeline cache and ISO hash cache\n"
      "  --log-file FILE          console log copy\n"
      "  --script FILE            deterministic input script (replaces physical input)\n"
      "  --frames N               stop after N retraces\n"
      "  --fast                   no real-time pacing\n"
      "  --time-base N            preset guest time base\n"
      "  --strict-aot             stop on any missing ahead-of-time translation\n"
      "  --audio-dump FILE.wav    record everything the AI DMA plays\n"
      "  --trace-calls --quiet --hang-watch SECONDS --version --help\n");
}

std::string executable_dir() {
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string path(size, '\0');
  if (_NSGetExecutablePath(path.data(), &size) != 0) return ".";
  path.resize(std::strlen(path.c_str()));
  std::error_code ec;
  const auto canonical = fs::canonical(path, ec);
  return (ec ? fs::path(path) : canonical).parent_path().string();
}

std::string home_dir() {
  const char* home = std::getenv("HOME");
  return home && *home ? home : ".";
}

std::string find_sys_dir() {
  if (const char* env = std::getenv("MELEE_SYS_DIR")) return env;
  const fs::path exe = executable_dir();
  for (const fs::path candidate : {exe / "slippi_sys", exe / "../Resources/slippi_sys", exe / "../../port/slippi_sys",
                                   exe / "../../../port/slippi_sys", fs::path("port/slippi_sys")}) {
    std::error_code ec;
    if (fs::is_directory(candidate / "GameFiles", ec)) return fs::weakly_canonical(candidate, ec).string();
  }
  return "";
}

// The Slippi Launcher keeps the netplay Dolphin's user.json here on macOS. Using the
// same folder makes this build see the same login and connect-code history.
std::string find_slippi_user_dir() {
  const fs::path support = fs::path(home_dir()) / "Library/Application Support";
  for (const fs::path candidate : {support / "com.project-slippi.dolphin/netplay/User/Slippi",
                                   support / "com.project-slippi.dolphin/netplay-beta/User/Slippi",
                                   support / "com.project-slippi.dolphin/Slippi",
                                   support / "Slippi Launcher/netplay/User/Slippi"}) {
    std::error_code ec;
    if (fs::is_regular_file(candidate / "user.json", ec)) return candidate.string();
  }
  return "";
}

bool ensure_dir(const std::string& path, const char* what) {
  std::error_code ec;
  fs::create_directories(path, ec);
  if (ec || !fs::is_directory(path, ec)) { std::fprintf(stderr, "cannot create %s directory %s\n", what, path.c_str()); return false; }
  return true;
}
}  // namespace

int main(int argc, char** argv) {
  host::Options& o = host::options;
  auto& online = slippi::online::config();
  bool allow_interpreter = true;
  int volume = 70;
  uint32_t window_w = 1280, window_h = 960;
  gx::MetalOptions gfx;
  std::string script, iso_arg, user_dir, sys_dir, replay_dir, card_dir, profile_dir, cache_dir, log_file;
  bool offline = false, choose_disc = false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto next = [&]() -> const char* { if (i + 1 >= argc) { usage(); std::exit(2); } return argv[++i]; };
    if (a == "--version") { std::printf("%s (macOS Metal/Aurora)\n", MELEE_PORT_VERSION); return 0; }
    else if (a == "--help" || a == "-h") { usage(); return 0; }
    else if (a == "--iso") iso_arg = next();
    else if (a == "--choose-disc") choose_disc = true;
    else if (a == "--volume") volume = std::atoi(next());
    else if (a == "--window") { if (std::sscanf(next(), "%ux%u", &window_w, &window_h) != 2 || window_w < 320 || window_h < 240) { usage(); return 2; } }
    else if (a == "--no-vsync") gfx.vsync = false;
    else if (a == "--scale") { std::string v = next(); gfx.efb_scale = v == "auto" ? 0 : std::atoi(v.c_str()); if (v != "auto" && gfx.efb_scale < 1) { usage(); return 2; } }
    else if (a == "--widescreen") gfx.widescreen = true;
    else if (a == "--sharpness") gfx.sharpness = std::clamp((float)std::atof(next()), 0.0f, 1.0f);
    else if (a == "--touch-overlay") host::touch_force_visible(true);
    else if (a == "--overlay-opacity") host::touch_set_opacity((float)std::atof(next()));
    else if (a == "--anisotropy") gfx.anisotropy = std::clamp(std::atoi(next()), 1, 16);
    else if (a == "--capture") gfx.capture_path = next();
    else if (a == "--capture-frame") gfx.capture_frame = (uint32_t)std::strtoul(next(), nullptr, 0);
    else if (a == "--capture-every") gfx.capture_every = (uint32_t)std::strtoul(next(), nullptr, 0);
    else if (a == "--offline") offline = true;
    else if (a == "--user-dir") user_dir = next();
    else if (a == "--online-delay") online.delay = std::atoi(next());
    else if (a == "--chat") { std::string v = next(); online.chat = v == "off" ? 2 : v == "direct" ? 1 : 0; }
    else if (a == "--netplay-port") slippi::Matchmaking::forced_port = (uint16_t)std::atoi(next());
    else if (a == "--local-peer") {
      // idx:local_port:remote_ip:remote_port; two instances peer directly without the matchmaking server.
      std::string v = next(); auto& lp = slippi::Matchmaking::local_peer;
      size_t a1 = v.find(':'), a2 = v.find(':', a1 + 1), a3 = v.find(':', a2 + 1);
      if (a1 == std::string::npos || a2 == std::string::npos || a3 == std::string::npos) { std::fprintf(stderr, "--local-peer idx:port:ip:port\n"); return 2; }
      lp.enabled = true; lp.local_index = std::atoi(v.substr(0, a1).c_str()); lp.local_port = (uint16_t)std::atoi(v.substr(a1 + 1, a2 - a1 - 1).c_str());
      lp.remote_ip = v.substr(a2 + 1, a3 - a2 - 1); lp.remote_port = (uint16_t)std::atoi(v.substr(a3 + 1).c_str()); }
    else if (a == "--sys-dir") sys_dir = next();
    else if (a == "--replay-dir") replay_dir = next();
    else if (a == "--card-dir") card_dir = next();
    else if (a == "--profile-dir") profile_dir = next();
    else if (a == "--cache-dir") cache_dir = next();
    else if (a == "--log-file") log_file = next();
    else if (a == "--script") script = next();
    else if (a == "--frames") o.frames = (uint32_t)std::strtoul(next(), nullptr, 0);
    else if (a == "--fast") o.fast = true;
    else if (a == "--time-base") { o.time_base = std::strtoull(next(), nullptr, 0); o.time_base_set = true; }
    else if (a == "--strict-aot") allow_interpreter = false;
    else if (a == "--allow-interpreter") allow_interpreter = true;
    else if (a == "--audio-dump") o.audio_dump = next();
    else if (a == "--trace-calls") o.trace_calls = true;
    else if (a == "--quiet") o.quiet = true;
    else if (a == "--hang-watch") o.hang_watch = std::atof(next());
    else if (!a.empty() && a[0] != '-' && iso_arg.empty()) iso_arg = a;   // drag-and-drop / open-with launch
    else { usage(); return 2; }
  }
  if (iso_arg.empty()) { if (const char* env = std::getenv("MELEE_ISO")) iso_arg = env; }

  const fs::path support = fs::path(home_dir()) / "Library/Application Support/MeleeUnlocked";
  // Without an explicit disc: reuse the last one, otherwise ask with a native open panel.
  const fs::path remembered = support / "launcher.ini";
  if (iso_arg.empty() || choose_disc) {
    std::string previous_error;
    if (!choose_disc) {
      std::ifstream in(remembered);
      std::string line;
      while (std::getline(in, line)) if (line.rfind("iso=", 0) == 0) iso_arg = line.substr(4);
      std::error_code ec;
      if (!iso_arg.empty() && !fs::is_regular_file(iso_arg, ec)) { previous_error = "The last disc image is no longer at " + iso_arg; iso_arg.clear(); }
    }
    if (iso_arg.empty()) iso_arg = host::mac_choose_disc(previous_error);
    if (iso_arg.empty()) return 0;
  }
  if (profile_dir.empty()) profile_dir = (support / "User").string();
  if (card_dir.empty()) card_dir = (fs::path(profile_dir) / "GC/CardA").string();
  if (replay_dir.empty()) replay_dir = (support / "Replays").string();
  if (cache_dir.empty()) cache_dir = (support / "Cache").string();
  if (log_file.empty()) log_file = (support / "melee_port.log").string();
  if (sys_dir.empty()) sys_dir = find_sys_dir();
  if (sys_dir.empty()) { std::fprintf(stderr, "cannot find the Slippi Sys folder; pass --sys-dir or set MELEE_SYS_DIR\n"); return 2; }
  for (const auto& [dir, what] : std::vector<std::pair<std::string, const char*>>{
           {profile_dir, "profile"}, {card_dir, "memory card"}, {replay_dir, "replay"}, {cache_dir, "cache"}})
    if (!ensure_dir(dir, what)) return 2;
  if (!offline && user_dir.empty()) user_dir = find_slippi_user_dir();
  if (!offline && user_dir.empty()) {
    user_dir = (support / "Slippi").string();
    ensure_dir(user_dir, "Slippi user");
  }

  o.iso = iso_arg;
  o.sys_dir = sys_dir;
  o.replay_dir = replay_dir;
  o.card_dir = card_dir;
  o.profile_dir = profile_dir;
  o.cache_dir = cache_dir;
  o.log_file = log_file;
  o.volume = std::clamp(volume, 0, 100);
  o.offline = offline;
  online.offline = offline;
  online.user_dir = user_dir.empty() ? profile_dir : user_dir;
  if (!script.empty() && !host::input_load_script(script.c_str())) { std::fprintf(stderr, "cannot load input script %s\n", script.c_str()); return 2; }
  ppc::set_interpreter_allowed(allow_interpreter);

  host::log("Melee Unlocked %s: macOS Metal/Aurora frontend", MELEE_PORT_VERSION);
  host::log("paths: iso=%s sys=%s profile=%s replays=%s cache=%s", o.iso.c_str(), o.sys_dir.c_str(), profile_dir.c_str(), replay_dir.c_str(), cache_dir.c_str());
  host::log("slippi: %s%s", offline ? "offline" : "online services enabled, user dir ", offline ? "" : online.user_dir.c_str());
  host::log("execution: %s, fp_profile=%s", allow_interpreter ? "interpreter fallback allowed" : "strict AOT", ppc::fp_profile_name(ppc::fp_profile()));
  if (!host::disc_open(o.iso)) {
    host::log("cannot open disc image %s", o.iso.c_str());
    std::fprintf(stderr, "cannot open ISO %s\n", o.iso.c_str());
    host::mac_show_error("Could not load this disc image", "Melee Unlocked needs an unmodified Super Smash Bros. Melee NTSC 1.02 image.\n\n" + o.iso);
    return 1;
  }
  { std::ofstream out(remembered, std::ios::trunc); out << "iso=" << o.iso << "\n"; }

  gecko::option_widescreen = gfx.widescreen;   // before the game loads the code table
  gx::Backend* backend = nullptr;
  bool audio_opened = false;
  int code = 0;
  try {
    void* layer = host::window_create((int)window_w, (int)window_h, L"Melee Unlocked", true);
    int client_w = 0, client_h = 0;
    host::window_client_size(&client_w, &client_h);
    backend = gx::create_metal_backend(layer, client_w, client_h, gfx);
    host::window_set_resize_callback([backend](int w, int h) { gx::metal_resize(backend, w, h); });
    gx::metal_set_overlay(backend, host::touch_overlay);
    host::g_has_window = true;
    gx::init(backend);
    if (!host::audio_open(o.volume, o.audio_dump.c_str(), true)) host::log("audio: device unavailable, continuing silent");
    audio_opened = true;

    ppc::init_dispatch();
    {
      ppc::ScopedGuestFpEnvironment fp_environment(0);
      host::boot_setup();
      host::log("boot: entering __start at 8000522C");
      try {
        ppc::call(*host::cpu, host::ram, 0x8000522Cu);
        host::log("guest returned from __start after %u retraces", host::retrace_count());
      } catch (const ExitRequested& stop) {
        code = stop.code;
      } catch (const LoadContextUnwind&) {
        host::log("OSLoadContext reached top level");
        code = 3;
      }
    }
  } catch (const std::exception& failure) {
    host::log("frontend exception: %s", failure.what());
    std::fprintf(stderr, "%s\n", failure.what());
    code = 3;
  }

  { uint64_t silent_ms = 0, underruns = host::audio_underruns(&silent_ms);
    double rate_low = 1.0, rate_high = 1.0; host::audio_rate_range(&rate_low, &rate_high);
    host::log("audio: %llu frames played, %llu blocks dropped, %llu gaps (%llu ms held), clock tracking %+.3f%% to %+.3f%%",
              (unsigned long long)host::audio_pushed_frames(), (unsigned long long)host::audio_dropped_blocks(),
              (unsigned long long)underruns, (unsigned long long)silent_ms, (rate_low - 1.0) * 100.0, (rate_high - 1.0) * 100.0); }
  gx::init(nullptr);
  host::g_has_window = false;
  if (audio_opened) host::audio_close();
  hle::dvd_shutdown();
  host::gcadapter_shutdown();
  slippi::shutdown();
  if (backend) {
    host::log("metal: %llu frames presented", (unsigned long long)gx::metal_frames_presented(backend));
    delete backend;
  }
  host::window_destroy();
  ppc::log_aot_diagnostics();
  { uint64_t calls = 0, insns = 0; ppc::interpreter_stats(&calls, &insns);
    if (calls) host::log("interpreter: %llu calls into RAM-resident code, %llu instructions", (unsigned long long)calls, (unsigned long long)insns); }
  host::log("slippi: %llu EXI commands, %llu replays written, GCT at %08X", (unsigned long long)slippi::commands_seen(),
            (unsigned long long)slippi::replays_written(), slippi::gct_load_address());
  host::log("result: exit=%d retraces=%u", code, host::retrace_count());
  host::close_log_file();
  return code;
}
