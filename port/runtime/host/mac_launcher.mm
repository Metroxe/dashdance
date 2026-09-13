// SPDX-License-Identifier: GPL-2.0-or-later
#import <AppKit/AppKit.h>
#include "mac_launcher.h"

namespace {
void prepare_application() {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  static bool launched = false;
  if (!launched) { [NSApp finishLaunching]; launched = true; }
  [NSApp activateIgnoringOtherApps:YES];
}
}  // namespace

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) {
  @autoreleasepool {
    prepare_application();
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithUTF8String:title.c_str()];
    alert.informativeText = [NSString stringWithUTF8String:detail.c_str()];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
  }
}

std::string mac_choose_disc(const std::string& previous_error) {
  @autoreleasepool {
    prepare_application();
    if (!previous_error.empty()) mac_show_error("Could not load this disc image", previous_error);
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = @"Melee Unlocked";
    panel.message = @"Choose your Super Smash Bros. Melee NTSC 1.02 disc image (.iso/.gcm).\n"
                     "The game is read from this file; nothing from it is included with the app.\n\n"
                     "Keyboard: arrows move · Z attack · X special · C/V jump · Q/W shield · E grab · Return start";
    panel.prompt = @"Play";
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return {};
    return std::string(panel.URL.fileSystemRepresentation);
  }
}
}  // namespace host
