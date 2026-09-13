// Developer-only oracle. Never link Reference Slippi into the game/runtime.
// SPDX-License-Identifier: GPL-2.0-or-later
// Compile against unchanged Common/FloatUtils.cpp from Reference Slippi
// 41a7a3a110ed52999486ae1901c8fbb9a63d4f13, with -ffp-model=strict.
#include "numeric.h"
#include "Common/FloatUtils.h"
#include <cstdio>

int main() {
  ppc::ScopedGuestFpEnvironment fp(0);
  // Reject a miscompiled oracle before making any differential claim.
  if (ppc::double_to_bits(Common::ApproximateReciprocalSquareRoot(1)) != 0x3feffe8000000000 ||
      ppc::double_to_bits(Common::ApproximateReciprocal(1)) != 0x3fefff0000000000 ||
      ppc::double_to_bits(Common::ApproximateReciprocalSquareRoot(
          ppc::bits_to_double(0xfff0000000000123))) != 0xfff8000000000123) {
    std::fprintf(stderr, "Pinned FloatUtils oracle failed golden qualification\n");
    return 2;
  }
  uint64_t comparisons = 0, failures = 0;
  auto compare = [&](uint64_t bits) {
    const double value = ppc::bits_to_double(bits);
    const uint64_t native[] = {ppc::double_to_bits(ppc::frsqrte(value)), ppc::double_to_bits(ppc::fres(value))};
    const uint64_t oracle[] = {ppc::double_to_bits(Common::ApproximateReciprocalSquareRoot(value)),
                               ppc::double_to_bits(Common::ApproximateReciprocal(value))};
    for (unsigned i = 0; i < 2; ++i) {
      ++comparisons;
      if (native[i] != oracle[i]) {
        if (++failures < 8) std::fprintf(stderr, "%s input=%016llx got=%016llx ref=%016llx\n",
          i ? "fres" : "frsqrte", (unsigned long long)bits,
          (unsigned long long)native[i], (unsigned long long)oracle[i]);
      }
    }
  };
  // Every table interval, each exponent parity, and both ends of unused low bits.
  for (uint64_t parity = 0; parity < 2; ++parity)
    for (uint64_t i = 0; i < 32768; ++i) {
      const uint64_t v = ((0x3ff + parity) << 52) | (i << 37);
      compare(v); compare(v | ((UINT64_C(1) << 37) - 1));
    }
  for (unsigned bit = 0; bit < 52; ++bit) {
    compare(UINT64_C(1) << bit);
    compare((UINT64_C(1) << bit) | UINT64_C(0x8000000000000000));
    compare((UINT64_C(1) << bit) | UINT64_C(0x7ff0000000000000));
    compare((UINT64_C(1) << bit) | UINT64_C(0xfff0000000000000));
  }
  uint64_t state = 0x5eedd00d12345678;
  for (unsigned i = 0; i < 262144; ++i) {
    state += UINT64_C(0x9e3779b97f4a7c15);
    uint64_t v = state;
    v = (v ^ (v >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    v = (v ^ (v >> 27)) * UINT64_C(0x94d049bb133111eb);
    compare(v ^ (v >> 31));
  }
  std::printf("Pinned Slippi estimate differential: %llu comparisons, %llu failures\n",
              (unsigned long long)comparisons, (unsigned long long)failures);
  return failures ? 1 : 0;
}
