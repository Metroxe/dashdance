// Synthetic dispatch table for CPU tests. No game content.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "ppc.h"
#include <cstddef>
namespace guest {
struct FnEntry { uint32_t addr; ppc::Fn fn; };
extern const FnEntry fn_table[];
extern const size_t fn_table_count;
}
