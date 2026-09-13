// No physical GameCube adapter support in this executable.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "host.h"
namespace host {
uint32_t gcadapter_poll(PadState[4]) { return 0; }
void gcadapter_rumble(int, bool) {}
void gcadapter_shutdown() {}
}  // namespace host
