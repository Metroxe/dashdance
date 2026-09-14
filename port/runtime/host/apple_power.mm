// Power and thermal management on Apple platforms: while a game runs, ask the system for latency-critical
// scheduling (no timer coalescing, no App Nap) and keep the display and system awake; log thermal-state
// changes so throttling shows up next to the frame timings it explains.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif
#include "host.h"
#include "gx_metal.h"

namespace host {
namespace {
id g_activity = nil;
id g_thermal_observer = nil;
const char* thermal_name(NSProcessInfoThermalState state) {
  switch (state) {
    case NSProcessInfoThermalStateNominal: return "nominal";
    case NSProcessInfoThermalStateFair: return "fair";
    case NSProcessInfoThermalStateSerious: return "serious (throttling)";
    case NSProcessInfoThermalStateCritical: return "critical (heavy throttling)";
  }
  return "unknown";
}
}  // namespace

const char* thermal_state_name() { return thermal_name(NSProcessInfo.processInfo.thermalState); }
namespace {
int g_device_cap = 0;
// Phones have the least thermal headroom: cap the internal resolution at 2x, and when the system reports
// serious or critical heat drop to 2x / 1x so the frame rate holds instead of the resolution.
void apply_caps() {
  const NSProcessInfoThermalState st = NSProcessInfo.processInfo.thermalState;
  const int thermal = st == NSProcessInfoThermalStateCritical ? 1 : st == NSProcessInfoThermalStateSerious ? 2 : 0;
  gx::metal_scale_caps(g_device_cap, thermal);
}
}  // namespace

void power_play_begin() {
  @autoreleasepool {
#if TARGET_OS_OSX
    if (!g_activity)
      g_activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleDisplaySleepDisabled | NSActivityIdleSystemSleepDisabled
                                                                reason:@"Playing Super Smash Bros. Melee"];
#else
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // the game is played with a controller: never dim the screen
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) g_device_cap = 2;
#endif
    apply_caps();
    log("power: latency-critical activity on, display sleep off, thermal state %s", thermal_state_name());
    if (!g_thermal_observer)
      g_thermal_observer = [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil
                                                                        usingBlock:^(NSNotification*) { log("power: thermal state now %s", thermal_state_name()); apply_caps(); }];
  }
}

void power_play_end() {
  @autoreleasepool {
#if TARGET_OS_OSX
    if (g_activity) { [NSProcessInfo.processInfo endActivity:g_activity]; g_activity = nil; }
#else
    UIApplication.sharedApplication.idleTimerDisabled = NO;
#endif
    if (g_thermal_observer) { [NSNotificationCenter.defaultCenter removeObserver:g_thermal_observer]; g_thermal_observer = nil; }
  }
}
}  // namespace host
