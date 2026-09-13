// Non-game Metal frontend seam tests.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "metal_frontend.h"
#include "gx_aurora_bridge.h"

#include <cassert>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
class InertNativeHost final : public host::MetalNativeHost {
public:
  host::MetalNativeEvents pump_events() override { return {}; }
  void resize(uint32_t, uint32_t) override {}
  host::MetalWindowSize window_size() const noexcept override { return {}; }
  void shutdown() noexcept override {}
};

class RecordingNativeHost final : public host::MetalNativeHost {
public:
  explicit RecordingNativeHost(std::vector<std::pair<uint32_t, uint32_t>>& sizes) : sizes_(sizes) {}
  host::MetalNativeEvents pump_events() override { return {}; }
  void resize(uint32_t width, uint32_t height) override { sizes_.emplace_back(width, height); }
  host::MetalWindowSize window_size() const noexcept override { return {}; }
  void shutdown() noexcept override {}

private:
  std::vector<std::pair<uint32_t, uint32_t>>& sizes_;
};

class ClosingNativeHost final : public host::MetalNativeHost {
public:
  host::MetalNativeEvents pump_events() override {
    return {.events = 4, .resize_events = 1, .close_requested = true};
  }
  void resize(uint32_t, uint32_t) override {}
  host::MetalWindowSize window_size() const noexcept override { return {}; }
  void shutdown() noexcept override {}
};

class SizedNativeHost final : public host::MetalNativeHost {
public:
  host::MetalNativeEvents pump_events() override { return {}; }
  void resize(uint32_t, uint32_t) override {}
  host::MetalWindowSize window_size() const noexcept override {
    return {.width = 960, .height = 720, .framebuffer_width = 1920, .framebuffer_height = 1440};
  }
  void shutdown() noexcept override {}
};

class RecordingBackend final : public gx::Backend {
public:
  explicit RecordingBackend(std::vector<uint64_t>& sequences) : sequences_(sequences) {}
  void submit_frame(const gx::Frame& frame) override { sequences_.push_back(frame.sequence); }

private:
  std::vector<uint64_t>& sequences_;
};

class UnsupportedBackend final : public gx::Backend {
public:
  void submit_frame(const gx::Frame&) override {
    throw gx::aurora_bridge::CoverageError("unsupported decoded GX state");
  }
};

class OrderedNativeHost final : public host::MetalNativeHost {
public:
  explicit OrderedNativeHost(std::vector<std::string>& order) : order_(order) {}
  host::MetalNativeEvents pump_events() override { return {}; }
  void resize(uint32_t, uint32_t) override {}
  host::MetalWindowSize window_size() const noexcept override { return {}; }
  void shutdown() noexcept override { order_.push_back("native-shutdown"); }

private:
  std::vector<std::string>& order_;
};

class OrderedBackend final : public gx::Backend {
public:
  explicit OrderedBackend(std::vector<std::string>& order) : order_(order) {}
  ~OrderedBackend() override { order_.push_back("renderer-destroy"); }
  void submit_frame(const gx::Frame&) override {}

private:
  std::vector<std::string>& order_;
};

void forwards_decoded_frames_in_order() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  gx::Frame first, second;
  first.sequence = 41;
  second.sequence = 42;

  frontend.submit_frame(first);
  frontend.submit_frame(second);

  assert((sequences == std::vector<uint64_t>{41, 42}));
}

void rejects_reversed_frame_before_the_renderer() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  gx::Frame newer, older;
  newer.sequence = 9;
  older.sequence = 8;
  frontend.submit_frame(newer);
  bool rejected = false;
  try {
    frontend.submit_frame(older);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }

  const auto stats = frontend.stats();
  assert(rejected && sequences == std::vector<uint64_t>{9} &&
         stats.submit_attempts == 2 && stats.unsupported.frame_order == 1);
}

void counts_renderer_coverage_rejections() {
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<UnsupportedBackend>());
  gx::Frame frame;
  frame.sequence = 5;
  bool rejected = false;
  try {
    frontend.submit_frame(frame);
  } catch (const gx::aurora_bridge::CoverageError&) {
    rejected = true;
  }

  const auto stats = frontend.stats();
  assert(rejected && stats.unsupported.render_state == 1 && stats.submit_attempts == 1);
}

void rejects_unvalidated_interpolation() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  gx::Frame frame;
  frame.sequence = 1;
  gx::DrawMatrices overrides{};
  bool rejected = false;
  try {
    frontend.submit_frame(frame, &overrides);
  } catch (const gx::aurora_bridge::CoverageError&) {
    rejected = true;
  }

  const auto stats = frontend.stats();
  assert(rejected && sequences.empty() && stats.unsupported.interpolation == 1);
}

void rejects_drain_without_present() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  bool rejected = false;
  try {
    frontend.set_skip_present(true);
  } catch (const gx::aurora_bridge::CoverageError&) {
    rejected = true;
  }

  assert(rejected && frontend.stats().unsupported.drain_without_present == 1);
}

void records_non_clear_output_evidence_after_successful_present() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  gx::Frame frame;
  frame.sequence = 12;
  frame.draws.resize(2);
  frame.copies.push_back({});
  frame.copies.back().to_xfb = true;

  frontend.submit_frame(frame);

  const auto stats = frontend.stats();
  assert(stats.presented_frames == 1 && stats.decoded_draws == 2 &&
         stats.presented_xfb == 1 && stats.has_real_output());
}

void forwards_window_resize_to_the_native_host() {
  std::vector<std::pair<uint32_t, uint32_t>> sizes;
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<RecordingNativeHost>(sizes),
                               std::make_unique<RecordingBackend>(sequences));

  frontend.resize(1280, 720);

  assert((sizes == std::vector<std::pair<uint32_t, uint32_t>>{{1280, 720}}) &&
         frontend.stats().resize_requests == 1);
}

void reports_native_events_and_close_requests() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<ClosingNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));

  const bool keep_running = frontend.pump_events();

  const auto stats = frontend.stats();
  assert(!keep_running && frontend.close_requested() &&
         stats.native_events == 4 && stats.resize_events == 1);
}

void reports_the_native_window_and_framebuffer_size() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<SizedNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));

  const auto size = frontend.window_size();

  assert(size.width == 960 && size.height == 720 &&
         size.framebuffer_width == 1920 && size.framebuffer_height == 1440);
}

void shuts_renderer_down_before_the_native_metal_session() {
  std::vector<std::string> order;
  {
    host::MetalFrontend frontend(std::make_unique<OrderedNativeHost>(order),
                                 std::make_unique<OrderedBackend>(order));
    frontend.shutdown();
    assert(!frontend.running());
  }

  assert((order == std::vector<std::string>{"renderer-destroy", "native-shutdown"}));
}

void rejects_submission_after_shutdown() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  frontend.shutdown();
  gx::Frame frame;
  bool rejected = false;
  try {
    frontend.submit_frame(frame);
  } catch (const std::logic_error&) {
    rejected = true;
  }

  assert(rejected && frontend.stats().unsupported.after_shutdown == 1);
}

void rejects_submission_from_a_non_owning_thread() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  bool rejected = false;
  std::thread worker([&] {
    gx::Frame frame;
    try {
      frontend.submit_frame(frame);
    } catch (const std::logic_error&) {
      rejected = true;
    }
  });
  worker.join();

  assert(rejected && sequences.empty() && frontend.stats().unsupported.wrong_thread == 1);
}

void rejects_event_pumping_after_shutdown() {
  std::vector<uint64_t> sequences;
  host::MetalFrontend frontend(std::make_unique<InertNativeHost>(),
                               std::make_unique<RecordingBackend>(sequences));
  frontend.shutdown();
  bool rejected = false;
  try {
    frontend.pump_events();
  } catch (const std::logic_error&) {
    rejected = true;
  }

  assert(rejected && frontend.stats().unsupported.after_shutdown == 1);
}
} // namespace

int main() {
  forwards_decoded_frames_in_order();
  rejects_reversed_frame_before_the_renderer();
  counts_renderer_coverage_rejections();
  rejects_unvalidated_interpolation();
  rejects_drain_without_present();
  records_non_clear_output_evidence_after_successful_present();
  forwards_window_resize_to_the_native_host();
  reports_native_events_and_close_requests();
  reports_the_native_window_and_framebuffer_size();
  shuts_renderer_down_before_the_native_metal_session();
  rejects_submission_after_shutdown();
  rejects_submission_from_a_non_owning_thread();
  rejects_event_pumping_after_shutdown();
  return 0;
}
