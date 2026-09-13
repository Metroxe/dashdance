// iOS/visionOS: the disc image is imported into the app's Documents folder through
// the Files app; the first .iso/.gcm found there is used. Errors are logged.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#include "mac_launcher.h"
#include <cstdio>

namespace host {
void mac_show_error(const std::string& title, const std::string& detail) {
  std::fprintf(stderr, "%s: %s\n", title.c_str(), detail.c_str());
}

std::string mac_choose_disc(const std::string&) {
  @autoreleasepool {
    NSArray<NSURL*>* documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    if (documents.count == 0) return {};
    NSArray<NSURL*>* entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:documents.firstObject
                                                            includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL* entry in entries) {
      NSString* extension = entry.pathExtension.lowercaseString;
      if ([extension isEqualToString:@"iso"] || [extension isEqualToString:@"gcm"]) return std::string(entry.fileSystemRepresentation);
    }
    std::fprintf(stderr, "No .iso/.gcm disc image in the app's Documents folder; add one with the Files app\n");
    return {};
  }
}
}  // namespace host
