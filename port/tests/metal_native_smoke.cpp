// Native Cocoa/Metal/Aurora initialization smoke. Does not load or run the game.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "metal_frontend.h"

#include <cstdio>
#include <exception>

int main(int argc, char** argv) {
  if (argc != 4) {
    std::fprintf(stderr, "usage: port_metal_native_smoke ABS_EMPTY_USER_DIR ABS_EMPTY_CACHE_DIR ABS_RESOURCES_DIR\n");
    return 2;
  }
  try {
    host::AuroraMetalConfig config;
    config.app_name = "Melee Unlocked Metal non-game smoke";
    config.user_path = argv[1];
    config.cache_path = argv[2];
    config.resources_path = argv[3];
    config.window_width = 320;
    config.window_height = 240;
    auto frontend = host::create_aurora_metal_frontend(config);
    frontend->pump_events();
    const auto size = frontend->window_size();
    if (!frontend->running() || !size.width || !size.height ||
        !size.framebuffer_width || !size.framebuffer_height)
      return 1;
    frontend->shutdown();
    std::printf("PASS: native Cocoa window, CAMetalLayer, Metal device and Aurora initialized\n");
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "Metal native smoke failed: %s\n", error.what());
    return 1;
  }
}
