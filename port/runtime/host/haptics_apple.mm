// Haptic feedback for touch controls: UIImpactFeedbackGenerator on iPhone/iPad, a
// no-op elsewhere (visionOS and macOS have no per-touch haptics).
// SPDX-License-Identifier: GPL-2.0-or-later
#include "overlay.h"
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

namespace host {
void haptic_tap(bool strong) {
#if TARGET_OS_IOS
  static UIImpactFeedbackGenerator* light = nil;
  static UIImpactFeedbackGenerator* medium = nil;
  if (!light) {
    light = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    medium = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [light prepare]; [medium prepare];
  }
  [(strong ? medium : light) impactOccurred];
#else
  (void)strong;
#endif
}
}  // namespace host
