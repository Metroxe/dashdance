// Confined fixtures only; never use an installed Slippi profile or game asset.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_game_file.h"
#include <array>
#include <chrono>
#include <cstdio>
#include <fstream>

namespace {
int failures = 0;
void check(bool condition, const char* message) {
  if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}
}

int main() {
  namespace fs = std::filesystem;
  using namespace slippi::files;
  for (const char* name : {"MxDt.dat", "MnExtAll.dat", "GameSetup_gui.dat", "MnSlMap.usd", "file-name_1.dat"})
    check(valid_name(name), "legitimate Slippi basename is accepted");
  for (const char* name : {"", ".", "..", "../x", "a/b.dat", "a\\b.dat", "/tmp/x", "C:x", "C:\\x", "a.", ".hidden"})
    check(!valid_name(name), "non-basename request is rejected");
  check(!valid_name(std::string_view("a\0b.dat", 7)), "embedded NUL cannot be part of a host filename");
  check(valid_name(std::string(63, 'A')) && !valid_name(std::string(64, 'A')), "guest name has a 63-byte maximum");

  std::array<uint8_t, 64> wire{};
  wire.fill('A'); wire.back() = 0;
  check(guest_name(wire.data(), wire.size()) == std::optional<std::string>(std::string(63, 'A')), "63 bytes plus NUL fit the guest field");
  wire.back() = 'A';
  check(!guest_name(wire.data(), wire.size()), "unterminated guest field is rejected");
  wire.fill(0); wire[0] = 'a'; wire[2] = '/'; wire[3] = '.'; wire[4] = '.';
  check(guest_name(wire.data(), wire.size()) == std::optional<std::string>("a"), "bytes after the first NUL cannot affect path resolution");
  check(!guest_name(wire.data(), 63) && !guest_name(nullptr, 64), "truncated or missing guest field is rejected");

  fs::path fixture;
  for (int attempt = 0; attempt < 100; ++attempt) {
    auto name = "slippi-game-files-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    auto candidate = fs::temp_directory_path() / name;
    if (fs::create_directory(candidate)) { fixture = candidate; break; }
  }
  check(!fixture.empty(), "test owns a newly created fixture directory");
  if (fixture.empty()) return 1;
  // Every path removed below is underneath this directory created by this test.
  struct Cleanup { fs::path path; ~Cleanup() { std::error_code ec; fs::remove_all(path, ec); } } cleanup{fixture};
  const auto sys = fixture / "Sys";
  const auto game = sys / "GameFiles" / "GALE01";
  fs::create_directories(game);
  fs::create_directory(fixture / "outside");
  std::ofstream(game / "MxDb.dat") << "local direct fixture";
  std::ofstream(game / "MnExtAll.dat.diff") << "local diff fixture";
  std::ofstream(fixture / "outside" / "outside.dat") << "outside fixture";
  fs::create_directory(game / "directory.dat");
  fs::create_directory(game / "directory.dat.diff");
  GameFileRoot root(sys);
  check(root.file("MxDb.dat", false) == fs::canonical(game / "MxDb.dat"), "direct lookup stays inside captured root");
  check(root.file("MnExtAll.dat", true) == fs::canonical(game / "MnExtAll.dat.diff"), "diff lookup stays inside captured root");
  for (const char* name : {"../outside.dat", "/outside.dat", "directory.dat", "missing.dat"}) {
    check(!root.file(name, false), "invalid or non-regular direct lookup is rejected");
    check(!root.file(name, true), "invalid or non-regular diff lookup is rejected");
  }
  std::error_code error;
  fs::create_symlink(fixture / "outside" / "outside.dat", game / "escape.dat", error);
  if (!error) {
    fs::create_symlink(fixture / "outside" / "outside.dat", game / "escape.dat.diff");
    check(!root.file("escape.dat", false) && !root.file("escape.dat", true), "direct and diff symlink escapes are rejected");
    fs::rename(game, sys / "original-game-files");
    fs::create_directory_symlink(fixture / "outside", game);
    check(!root.directory() && !root.file("outside.dat", false), "preload and reads reject a replaced game directory outside Sys");
  } else {
    // Windows can require a separate privilege for creating a symlink. The name
    // and regular-file assertions above remain active on that host.
    std::fprintf(stderr, "SKIP: symlink fixture unavailable on this host\n");
  }
  return failures ? 1 : 0;
}
