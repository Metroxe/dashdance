// See controller_rate.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <GameController/GameController.h>
#include "controller_rate.h"
#include "host.h"
#include <algorithm>
#include <mutex>
#include <unordered_map>

namespace host {
namespace {
struct Track {
  std::string name; bool wired = false;
  double last = 0.0;
  std::vector<double> intervals;   // seconds between consecutive change events, newest last (bounded)
  unsigned samples = 0;
};
std::mutex g_mutex;
std::unordered_map<const void*, Track> g_tracks;   // keyed by the GCController object
dispatch_queue_t g_queue = nullptr;
id g_connect = nil, g_disconnect = nil;

void record(GCController* controller) {
  const double now = now_seconds();
  std::lock_guard<std::mutex> lock(g_mutex);
  Track& t = g_tracks[(__bridge const void*)controller];
  if (t.last > 0.0) {
    const double dt = now - t.last;
    if (dt > 0.0002 && dt < 0.05) {   // a report interval, not an idle gap
      if (t.intervals.size() >= 256) t.intervals.erase(t.intervals.begin());
      t.intervals.push_back(dt); ++t.samples;
    }
  }
  t.last = now;
}

void attach(GCController* controller) {
  if (!controller) return;
  if (!g_queue) g_queue = dispatch_queue_create("app.islippi.controller-events", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
  controller.handlerQueue = g_queue;   // change handlers (ours) run off the main thread, at user-interactive priority
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    Track& t = g_tracks[(__bridge const void*)controller];
    t.name = controller.vendorName ? controller.vendorName.UTF8String : "Controller";
    t.wired = controller.attachedToDevice;
  }
  __weak GCController* weak = controller;
  if (controller.extendedGamepad) controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad*, GCControllerElement*) { if (GCController* c = weak) record(c); };
  else if (controller.microGamepad) controller.microGamepad.valueChangedHandler = ^(GCMicroGamepad*, GCControllerElement*) { if (GCController* c = weak) record(c); };
  log("controller: %s connected (%s)", controller.vendorName.UTF8String ?: "controller", controller.attachedToDevice ? "wired" : "wireless");
}
void detach(GCController* controller) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_tracks.erase((__bridge const void*)controller);
}
}  // namespace

void controller_rate_init() {
  @autoreleasepool {
    for (GCController* c in GCController.controllers) attach(c);
    g_connect = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification* n) { attach((GCController*)n.object); }];
    g_disconnect = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification* n) { detach((GCController*)n.object); }];
  }
}

std::vector<ControllerReport> controller_reports() {
  std::vector<ControllerReport> out;
  std::lock_guard<std::mutex> lock(g_mutex);
  for (auto& [key, t] : g_tracks) {
    ControllerReport r; r.name = t.name; r.wired = t.wired; r.samples = t.samples;
    if (t.intervals.size() >= 16) {
      // Reports arrive at a fixed interval while a stick moves; the 10th percentile ignores the idle gaps in between.
      std::vector<double> v = t.intervals; std::sort(v.begin(), v.end());
      r.hz = 1.0 / v[v.size() / 10];
    }
    out.push_back(r);
  }
  return out;
}
}  // namespace host
