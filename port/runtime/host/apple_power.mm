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
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#endif
#include "host.h"
#include "gx_metal.h"
#include <atomic>

#if !TARGET_OS_OSX && !TARGET_OS_VISION
// Holds the display at its highest refresh rate while a game runs. A ProMotion iPhone or iPad otherwise lowers the panel
// to 60 Hz for 60 fps content, and a finished frame can then wait up to 16.7 ms for its slot instead of 8.3 ms. The link
// lives on its own thread, so it keeps ticking while the game's main thread sleeps between frames.
@interface MUDisplayPacer : NSObject
@property(nonatomic) NSThread* thread;
@property(nonatomic) NSInteger hz;
@end
@implementation MUDisplayPacer
- (void)tick:(CADisplayLink*)link {}
- (void)run {
  @autoreleasepool {
    CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    const float hz = (float)self.hz;
    link.preferredFrameRateRange = CAFrameRateRangeMake(hz, hz, hz);
    [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    while (!NSThread.currentThread.cancelled) {
      @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]]; }
    }
    [link invalidate];
  }
}
@end
#endif

namespace host {
namespace {
id g_activity = nil;
std::atomic<bool> g_low_power{false}, g_bluetooth_audio{false};
id g_power_observer = nil, g_route_observer = nil;
#if !TARGET_OS_OSX && !TARGET_OS_VISION   // Vision Pro composites every window at the headset's fixed rate: nothing to raise
MUDisplayPacer* g_pacer = nil;
NSInteger screen_max_hz() {
  UIScreen* screen = nil;   // the screen the app's scene is on, not a global main screen (iPhone Duo has two)
  for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) { screen = ((UIWindowScene*)sc).screen; break; }
  return MAX((NSInteger)60, (screen ?: UIScreen.mainScreen).maximumFramesPerSecond);
}
#endif
#if !TARGET_OS_OSX
bool route_is_wireless() {
  for (AVAudioSessionPortDescription* port in AVAudioSession.sharedInstance.currentRoute.outputs) {
    NSString* t = port.portType;
    if ([t isEqualToString:AVAudioSessionPortBluetoothA2DP] || [t isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [t isEqualToString:AVAudioSessionPortBluetoothHFP] || [t isEqualToString:AVAudioSessionPortAirPlay]) return true;
  }
  return false;
}
#endif
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

const char* latency_warning() {
  const bool lpm = g_low_power.load(), bt = g_bluetooth_audio.load();
  return lpm && bt ? "Low Power Mode on  ·  Bluetooth audio lags" : lpm ? "Low Power Mode on" : bt ? "Bluetooth audio lags" : "";
}
void audio_session_report() {
#if !TARGET_OS_OSX
  @autoreleasepool {
    AVAudioSession* session = AVAudioSession.sharedInstance;
    g_bluetooth_audio = route_is_wireless();
    NSString* route = session.currentRoute.outputs.firstObject.portName ?: @"none";
    log("audio session: IO buffer %.1f ms (asked 5.0), output latency %.1f ms, route %s%s", session.IOBufferDuration * 1000.0, session.outputLatency * 1000.0,
        route.UTF8String, g_bluetooth_audio.load() ? " (wireless: sound will lag the picture; wired or built-in audio is faster)" : "");
  }
#endif
}
void power_play_begin() {
  @autoreleasepool {
    g_low_power = NSProcessInfo.processInfo.lowPowerModeEnabled;
    if (!g_power_observer)
      g_power_observer = [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification*) {
        g_low_power = NSProcessInfo.processInfo.lowPowerModeEnabled;
        log("power: Low Power Mode %s", g_low_power.load() ? "on (the system limits the display and the CPU)" : "off");
      }];
    if (g_low_power.load()) log("power: Low Power Mode is on: the system limits the display to 60 Hz and slows the CPU, which adds latency");
#if TARGET_OS_OSX
    if (!g_activity)
      g_activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleDisplaySleepDisabled | NSActivityIdleSystemSleepDisabled
                                                                reason:@"Playing Super Smash Bros. Melee"];
#else
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // the game is played with a controller: never dim the screen
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) g_device_cap = 2;
#if !TARGET_OS_VISION
    if (!g_pacer) {
      g_pacer = [[MUDisplayPacer alloc] init];
      g_pacer.hz = screen_max_hz();
      g_pacer.thread = [[NSThread alloc] initWithTarget:g_pacer selector:@selector(run) object:nil];
      g_pacer.thread.name = @"display pacer"; g_pacer.thread.qualityOfService = NSQualityOfServiceUtility;
      [g_pacer.thread start];
      log("display: holding the panel at %ld Hz while playing, so a finished frame waits at most %.1f ms for its refresh", (long)g_pacer.hz, 1000.0 / g_pacer.hz);
    }
#endif
    // Audio: a small hardware buffer so sound lands with the frame that made it (iOS defaults to about 20 ms), and no
    // system alert sounds cutting into a match. SDL activates the session when it opens the device; these preferences apply then.
    AVAudioSession* session = AVAudioSession.sharedInstance;
    [session setPreferredSampleRate:48000 error:nil];
    [session setPreferredIOBufferDuration:0.005 error:nil];
#if !TARGET_OS_VISION
    [session setPrefersNoInterruptionsFromSystemAlerts:YES error:nil];
#endif
    g_bluetooth_audio = route_is_wireless();
    if (!g_route_observer)
      g_route_observer = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification*) {
        const bool wireless = route_is_wireless();
        if (wireless != g_bluetooth_audio.load()) log("audio: output is now %s", wireless ? "wireless (sound lags the picture)" : "wired or built-in");
        g_bluetooth_audio = wireless;
      }];
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
#if !TARGET_OS_VISION
    if (g_pacer) { [g_pacer.thread cancel]; g_pacer = nil; }   // back to the system's adaptive refresh: saves battery in menus
#endif
    if (g_route_observer) { [NSNotificationCenter.defaultCenter removeObserver:g_route_observer]; g_route_observer = nil; }
#endif
    if (g_power_observer) { [NSNotificationCenter.defaultCenter removeObserver:g_power_observer]; g_power_observer = nil; }
    if (g_thermal_observer) { [NSNotificationCenter.defaultCenter removeObserver:g_thermal_observer]; g_thermal_observer = nil; }
  }
}
}  // namespace host
