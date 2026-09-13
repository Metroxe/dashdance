#include "dvd_read_worker.h"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <mutex>
#include <thread>

namespace {
using namespace std::chrono_literals;
using hle::dvd_detail::ReadStatus;
using hle::dvd_detail::ReadWorker;

void check(bool ok) {
  if (!ok) std::abort();
}

void idempotent_lifecycle_and_reuse() {
  int reads = 0;
  ReadWorker worker([&](uint32_t offset, void* dst, uint32_t size) {
    ++reads;
    std::memset(dst, static_cast<int>(offset), size);
    return true;
  });

  worker.shutdown();
  worker.shutdown();
  check(!worker.accepting());
  worker.initialize();
  worker.initialize();
  auto first = worker.submit(0x5a, 8);
  check(first != nullptr);
  worker.wait(first);
  check(first->status.load() == ReadStatus::complete);
  check(first->data.size() == 8 && first->data.front() == 0x5a && reads == 1);

  worker.shutdown();
  worker.shutdown();
  check(!worker.accepting());
  check(worker.submit(0, 1) == nullptr);

  worker.initialize();
  auto second = worker.submit(0x2b, 0);
  check(second != nullptr);
  worker.wait(second);
  check(second->status.load() == ReadStatus::complete && second->data.empty() && reads == 2);
  worker.shutdown();
}

void shutdown_cancels_queued_and_joins_in_flight() {
  struct SlowRead {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool release = false;
    int calls = 0;
  } slow;

  ReadWorker worker([&](uint32_t, void* dst, uint32_t size) {
    std::unique_lock<std::mutex> lock(slow.mutex);
    ++slow.calls;
    slow.entered = true;
    slow.cv.notify_all();
    slow.cv.wait(lock, [&] { return slow.release; });
    lock.unlock();
    std::memset(dst, 0xa5, size);
    return true;
  });

  worker.initialize();
  auto in_flight = worker.submit(0x1000, 16);
  check(in_flight != nullptr);
  {
    std::unique_lock<std::mutex> lock(slow.mutex);
    check(slow.cv.wait_for(lock, 1s, [&] { return slow.entered; }));
  }
  check(in_flight->status.load() == ReadStatus::reading);
  auto queued = worker.submit(0x2000, 16);
  check(queued != nullptr);
  check(queued->status.load() == ReadStatus::queued);

  auto stopping = std::async(std::launch::async, [&] { worker.shutdown(); });
  worker.wait(queued);
  check(queued->status.load() == ReadStatus::cancelled);
  check(stopping.wait_for(20ms) == std::future_status::timeout);
  {
    std::lock_guard<std::mutex> lock(slow.mutex);
    check(slow.calls == 1);
    slow.release = true;
  }
  slow.cv.notify_all();
  stopping.get();

  check(in_flight->status.load() == ReadStatus::complete);
  check(in_flight->data.size() == 16 && in_flight->data.front() == 0xa5);
  check(!worker.accepting() && worker.submit(0, 1) == nullptr);
}

void failed_read_quiesces_before_fatal_dispatch() {
  bool fail = true;
  std::thread::id read_thread;
  ReadWorker worker([&](uint32_t, void* dst, uint32_t size) {
    read_thread = std::this_thread::get_id();
    if (fail) return false;
    std::memset(dst, 0x6d, size);
    return true;
  });

  worker.initialize();
  auto failed = worker.submit(0x3000, 8);
  check(failed != nullptr);
  worker.wait(failed);
  check(failed->status.load() == ReadStatus::failed);
  // Read failures are status-only on the worker. The simulation/fatal-boundary thread owns
  // shutdown and can join immediately without re-entering a worker-held lock or self-joining.
  check(read_thread != std::this_thread::get_id());
  worker.shutdown();
  check(!worker.accepting());

  fail = false;
  worker.initialize();
  auto recovered = worker.submit(0x3000, 8);
  check(recovered != nullptr);
  worker.wait(recovered);
  check(recovered->status.load() == ReadStatus::complete);
  check(recovered->data.size() == 8 && recovered->data.front() == 0x6d);
  worker.shutdown();
}
}  // namespace

int main() {
  idempotent_lifecycle_and_reuse();
  shutdown_cancels_queued_and_joins_in_flight();
  failed_read_quiesces_before_fatal_dispatch();
  std::puts("DVD worker lifecycle, cancellation, in-flight join and fatal quiescence passed");
}
