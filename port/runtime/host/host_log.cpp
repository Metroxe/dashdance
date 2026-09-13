// Complete log records and lifecycle operations share one lock. Once finalized,
// the sink cannot be reopened or changed by a delayed producer.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "host.h"
#include "fatal_boundary.h"
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <mutex>

namespace host {
namespace {
std::mutex log_mutex;
FILE* log_file = nullptr;
bool log_tried = false, log_closed = false;
FatalObserver fatal_observer;
std::atomic_flag observer_active = ATOMIC_FLAG_INIT;
void open_log_file() {
  if (log_tried || log_closed) return;
  log_tried = true;
  log_file = std::fopen(options.log_file.empty() ? "melee_port.log" : options.log_file.c_str(), "w");
}
}
void close_log_file() {
  std::lock_guard<std::mutex> lock(log_mutex);
  if (log_file) { std::fflush(log_file); std::fclose(log_file); log_file = nullptr; }
  log_closed = true;
}
void set_fatal_observer(FatalObserver observer) {
  std::lock_guard<std::mutex> lock(log_mutex);
  fatal_observer = std::move(observer);
}
void notify_fatal_observer(const std::string& reason) {
  if (observer_active.test_and_set()) return;
  FatalObserver observer;
  { std::lock_guard<std::mutex> lock(log_mutex); observer = fatal_observer; }
  if (observer) {
    try { observer(reason); } catch (...) { std::fputs("cannot finalize fatal diagnostics\n", stderr); }
  }
  observer_active.clear();
}
void log(const char* fmt, ...) {
  if (options.quiet) return;
  std::lock_guard<std::mutex> lock(log_mutex);
  if (log_closed) return;
  open_log_file();
  va_list args; va_start(args, fmt); std::vfprintf(stdout, fmt, args); va_end(args);
  std::fputc('\n', stdout); std::fflush(stdout);
  if (log_file) {
    va_list copy; va_start(copy, fmt); std::vfprintf(log_file, fmt, copy); va_end(copy);
    std::fputc('\n', log_file); std::fflush(log_file);
  }
}
void log_guest_text(const char* data, size_t size) {
  std::lock_guard<std::mutex> lock(log_mutex);
  if (log_closed) return;
  std::fwrite(data, 1, size, stdout); std::fflush(stdout);
  if (log_file) { std::fwrite(data, 1, size, log_file); std::fflush(log_file); }
}
[[noreturn]] void die(const char* fmt, ...) {
  char reason[4096];
  va_list args; va_start(args, fmt); std::vsnprintf(reason, sizeof reason, fmt, args); va_end(args);
  {
    std::lock_guard<std::mutex> lock(log_mutex);
    std::fprintf(stderr, "\nFATAL: %s\n", reason);
    if (!log_closed && log_file) { std::fprintf(log_file, "\nFATAL: %s\n", reason); std::fflush(log_file); }
    std::fflush(stderr); std::fflush(stdout);
  }
  if (fatal_boundary_active()) throw HostFatal(reason);
  notify_fatal_observer(reason);
  std::exit(3);
}
}  // namespace host
