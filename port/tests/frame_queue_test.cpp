#include "frame_queue.h"
#include <cstdio>
#include <cstdlib>
#include <future>
static void check(bool ok) { if (!ok) std::abort(); }
static gx::Frame frame(uint64_t sequence) { gx::Frame f; f.sequence = sequence; return f; }
int main() {
  gx::FrameQueue queue;
  for (size_t i = 1; i <= gx::FrameQueue::capacity; ++i) check(queue.push(frame(i)));
  check(queue.size() == gx::FrameQueue::capacity);
  auto blocked = std::async(std::launch::async, [&] { return queue.push(frame(gx::FrameQueue::capacity + 1)); });
  check(blocked.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout);
  gx::Frame out;
  check(queue.pop(out) && out.sequence == 1);
  check(blocked.get());
  queue.finish();
  check(!queue.push(frame(4)));
  for (size_t i = 2; i <= gx::FrameQueue::capacity + 1; ++i) check(queue.pop(out) && out.sequence == i);
  check(queue.drained() && !queue.pop(out));
  gx::FrameQueue cancelled;
  for (size_t i = 1; i <= gx::FrameQueue::capacity; ++i) check(cancelled.push(frame(i)));
  auto waiting = std::async(std::launch::async, [&] { return cancelled.push(frame(gx::FrameQueue::capacity + 1)); });
  check(waiting.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout);
  cancelled.finish(true);
  check(!waiting.get() && cancelled.drained());
  gx::FrameQueue recycled;
  for (size_t i = 1; i <= gx::FrameQueue::capacity; ++i) check(recycled.push(frame(i)));
  gx::Frame incoming = frame(gx::FrameQueue::capacity + 1);
  incoming.vertices.resize(3);
  auto recycling = std::async(std::launch::async, [&] { return recycled.push_and_recycle(incoming); });
  check(recycling.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout);
  check(recycled.pop(out) && out.sequence == 1);
  check(recycling.get() && incoming.vertices.empty());
  recycled.finish();
  for (size_t i = 2; i <= gx::FrameQueue::capacity + 1; ++i) check(recycled.pop(out) && out.sequence == i);
  check(out.vertices.size() == 3 && recycled.drained());
  std::puts("bounded ordering, drain, cancellation and producer wakeup passed");
}
