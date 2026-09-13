// Launch isolation checks do not execute the guest or read a real disc/profile.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "headless_options.h"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;
static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
static host::HeadlessParse parse(const std::vector<std::string>& args, host::HeadlessOptions& options, std::string& error) {
  std::vector<const char*> pointers;
  for (const auto& arg : args) pointers.push_back(arg.c_str());
  return host::parse_headless_options(int(pointers.size()), pointers.data(), options, error);
}
static void replace(std::vector<std::string>& args, const std::string& key, const std::string& value) {
  for (size_t i = 0; i + 1 < args.size(); ++i) if (args[i] == key) { args[i + 1] = value; return; }
  args.push_back(key); args.push_back(value);
}
int main() {
  std::string temporary = (fs::temp_directory_path() / "melee-options-test-XXXXXX").string();
  std::vector<char> path(temporary.begin(), temporary.end()); path.push_back(0);
  require(::mkdtemp(path.data()) != nullptr, "create isolated options test directory");
  fs::path root = fs::canonical(path.data());
  fs::path iso = root / "synthetic.iso", sys = root / "sys", alias = root / "alias";
  FILE* file = std::fopen(iso.c_str(), "wbx"); require(file != nullptr, "create synthetic input"); std::fclose(file);
  fs::create_directory(sys);
  fs::create_directory_symlink(root, alias);
  std::vector<std::string> base = {"headless", "--offline", "--iso", iso.string(), "--sys-dir", sys.string(),
    "--frames", "1", "--time-base", "0", "--profile-dir", (root / "profile").string(),
    "--card-dir", (root / "card").string(), "--cache-dir", (root / "cache").string(), "--validate-only"};
  host::HeadlessOptions options;
  std::string error;
  require(parse({"headless"}, options, error) == host::HeadlessParse::Error, "empty invocation fails closed");
  require(parse({"headless", "--offline", "--iso"}, options, error) == host::HeadlessParse::Error, "missing argument fails closed");
  require(parse(base, options, error) == host::HeadlessParse::Ready, error.c_str());
  require(options.runtime.time_base_set && options.runtime.time_base == 0, "explicit zero timebase is deterministic");
  require(options.runtime.offline && !options.allow_interpreter, "offline strict-AOT launch");
  { auto args = base; replace(args, "--expect-scene", "0x0202");
    require(parse(args, options, error) == host::HeadlessParse::Ready && options.expect_scene && options.expected_scene == 0x0202,
            "explicit combined expected scene"); }
  require(!fs::exists(root / "profile") && !fs::exists(root / "card") && !fs::exists(root / "cache"), "validation does not create outputs");
  auto reject = [&](std::vector<std::string> args, const char* what) { require(parse(args, options, error) == host::HeadlessParse::Error, what); };
  for (const char* bad : {"0", "36001", "-1", "1x", "18446744073709551616"}) {
    auto args = base; replace(args, "--frames", bad); reject(args, "invalid frame bound rejected");
  }
  { auto args = base; replace(args, "--profile-dir", sys.string()); reject(args, "existing directory rejected"); }
  { auto args = base; replace(args, "--profile-dir", "relative-profile"); reject(args, "relative output rejected"); }
  { auto args = base; replace(args, "--card-dir", (alias / "profile").string()); reject(args, "symlink-parent canonical collision rejected"); }
  { auto args = base; replace(args, "--log-file", (root / "cache" / ".." / "escaped.log").string()); reject(args, "output leaf escape rejected"); }
  { auto args = base; replace(args, "--log-file", (root / "cache" / "replays").string()); reject(args, "replay directory cannot become a log file"); }
  for (const char* reserved : {"launch.json", "result.json", "launch.json.tmp", "result.json.tmp"}) {
    auto args = base; replace(args, "--log-file", (root / "cache" / reserved).string()); reject(args, "manifest artifacts cannot alias user output");
  }
  { auto args = base; replace(args, "--expect-scene", "0x10000"); reject(args, "out-of-range scene rejected"); }
  { auto args = base; replace(args, "--expect-scene", "02:02"); reject(args, "ambiguous colon scene rejected"); }
  { auto args = base; replace(args, "--gx-capture-sequence", "2"); reject(args, "capture sequence requires capture path"); }
  { auto args = base; replace(args, "--gx-capture", (root / "cache" / "frame.gx").string()); replace(args, "--gx-capture-sequence", "2"); reject(args, "capture must be inside frame bound"); }
  { auto args = base; replace(args, "--state-trace", (root / "cache" / "melee_port.log").string()); reject(args, "aliased output files rejected"); }
  { auto args = base; args.push_back("--strict-aot"); args.push_back("--allow-interpreter"); reject(args, "contradictory interpreter flags rejected"); }
  { auto args = base; replace(args, "--cache-dir", (root / "absent" / "cache").string()); reject(args, "missing output parent rejected"); }
  fs::create_symlink(root / "absent-profile", root / "profile");
  reject(base, "dangling output symlink rejected");
  fs::remove(root / "profile");
  { auto args = base; replace(args, "--cache-dir", (alias / "cache").string());
    replace(args, "--log-file", (alias / "cache" / "run.log").string());
    require(parse(args, options, error) == host::HeadlessParse::Ready, "consistent symlink-parent aliases accepted");
    require(options.runtime.cache_dir == (root / "cache").string(), "output path is canonicalized"); }
  require(parse(base, options, error) == host::HeadlessParse::Ready, error.c_str());
  require(host::prepare_headless_outputs(options, error), error.c_str());
  require(fs::is_directory(root / "cache" / "replays"), "fresh replay directory created inside cache");
  require(!host::prepare_headless_outputs(options, error), "second reservation cannot reuse a profile");
  fs::remove(root / "cache" / "replays"); fs::remove(root / "cache"); fs::remove(root / "card"); fs::remove(root / "profile");
  fs::remove(alias); fs::remove(sys); fs::remove(iso); fs::remove(root);
}
