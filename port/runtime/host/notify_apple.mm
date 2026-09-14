// Local notifications on macOS: "match found" while the app is not frontmost. Only possible from an
// app bundle (the bare development binary has no bundle identifier, and the system refuses it), and
// only useful on the Mac: on iOS the game cannot keep searching in the background.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif
#include "host.h"

namespace host {
namespace {
bool g_asked = false, g_allowed = false;
}
void notify_local(const std::string& title, const std::string& body) {
#if TARGET_OS_OSX
  @autoreleasepool {
    if (!NSBundle.mainBundle.bundleIdentifier) { log("notify: %s — %s (not delivered: not running as an app bundle)", title.c_str(), body.c_str()); return; }
    if (NSApp.isActive) return;   // the player is looking at the game
    UNUserNotificationCenter* center = UNUserNotificationCenter.currentNotificationCenter;
    if (!g_asked) {
      g_asked = true;
      [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError*) { g_allowed = granted; }];
    }
    UNMutableNotificationContent* c = [[UNMutableNotificationContent alloc] init];
    c.title = [NSString stringWithUTF8String:title.c_str()]; c.body = [NSString stringWithUTF8String:body.c_str()]; c.sound = UNNotificationSound.defaultSound;
    UNNotificationRequest* r = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString content:c trigger:nil];
    [center addNotificationRequest:r withCompletionHandler:^(NSError* error) { if (error) log("notify: %s", error.localizedDescription.UTF8String); }];
  }
#else
  (void)title; (void)body;
#endif
}
}  // namespace host
