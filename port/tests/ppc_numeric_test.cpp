// Real runtime helpers, independent of generated game content or host services.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "ppc.h"
#include <atomic>
#include <cfenv>
#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>

namespace {
unsigned failures = 0, checks = 0;
void equal(const char* name, uint64_t actual, uint64_t expected) {
  ++checks;
  if (actual != expected) {
    ++failures;
    std::fprintf(stderr, "%s: got %016llx expected %016llx\n", name,
                 (unsigned long long)actual, (unsigned long long)expected);
  }
}
void bits(const char* name, double actual, uint64_t expected) {
  equal(name, ppc::double_to_bits(actual), expected);
}
constexpr uint64_t sign = UINT64_C(0x8000000000000000);
void integers() {
  equal("byte swap16", ppc::bswap16(0x1234), 0x3412);
  equal("byte swap32", ppc::bswap32(0x01234567), 0x67452301);
  equal("byte swap64", ppc::bswap64(0x0123456789abcdef), 0xefcdab8967452301);
  equal("cntlzw zero", ppc::cntlzw(0), 32);
  for (unsigned i = 0; i < 32; ++i) equal("cntlzw bit", ppc::cntlzw(1u << i), 31 - i);
  const uint32_t values[] = {0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x81234567};
  for (uint32_t v : values) {
    for (uint32_t n = 0; n < 128; ++n) {
      uint32_t rotated = 0;
      for (uint32_t bit = 0; bit < 32; ++bit)
        if (v & (1u << bit)) rotated |= 1u << ((bit + n) & 31);
      equal("rotate", ppc::rotl32(v, n), rotated);
      ppc::Context c{};
      uint32_t expected, carry;
      if (n & 32) { expected = (v & 0x80000000u) ? 0xffffffffu : 0; carry = expected != 0; }
      else {
        const int64_t divisor = INT64_C(1) << (n & 31);
        const int64_t sv = ppc::signed_word(v);
        const int64_t quotient = sv / divisor - ((sv < 0 && sv % divisor) ? 1 : 0);
        expected = uint32_t(quotient);
        carry = sv < 0 && sv % divisor;
      }
      equal("sraw", ppc::sraw(c, v, n), expected);
      equal("sraw carry", c.ca, carry);
      if (n < 32) {
        equal("srawi", ppc::srawi(c, v, int(n)), expected);
        equal("srawi carry", c.ca, carry);
      }
    }
  }
  equal("mulhw negative", ppc::mulhw(0xffffffff, 2), 0xffffffff);
  equal("mulhw INT_MIN squared", ppc::mulhw(0x80000000, 0x80000000), 0x40000000);
  equal("mulhw opposite", ppc::mulhw(0x80000000, 0x7fffffff), 0xc0000000);
  equal("divw overflow", ppc::divw(INT32_MIN, -1), 0);
  equal("divw divide zero", ppc::divw(-1, 0), 0xffffffff);
}
void rounding() {
  const int host_modes[] = {FE_TONEAREST, FE_TOWARDZERO, FE_UPWARD, FE_DOWNWARD};
  const uint64_t positive[] = {0x3ff0000000000000, 0x3ff0000000000000,
                               0x3ff0000000000001, 0x3ff0000000000000};
  const uint64_t negative[] = {0xbff0000000000000, 0xbff0000000000000,
                               0xbff0000000000000, 0xbff0000000000001};
  const uint64_t single_pos[] = {0x3ff0000000000000, 0x3ff0000000000000,
                                 0x3ff0000020000000, 0x3ff0000000000000};
  const uint64_t single_neg[] = {0xbff0000000000000, 0xbff0000000000000,
                                 0xbff0000000000000, 0xbff0000020000000};
  for (uint32_t rn = 0; rn < 4; ++rn) {
    ppc::set_fp_environment(rn);
    equal("host round mode", std::fegetround(), host_modes[rn]);
    bits("fadd half ulp", ppc::fadd(1.0, 0x1p-53), positive[rn]);
    bits("fsub half ulp", ppc::fsub(-1.0, 0x1p-53), negative[rn]);
    bits("fmadd half ulp", ppc::fmadd(1.0, 1.0, 0x1p-53), positive[rn]);
    bits("fnmadd round then negate", ppc::fnmadd(1.0, 1.0, 0x1p-53), positive[rn] ^ sign);
    bits("fnmsub round then negate", ppc::fnmsub(1.0, 1.0, -0x1p-53), positive[rn] ^ sign);
    bits("frsp positive", ppc::fs(1.0 + 0x1p-24), single_pos[rn]);
    bits("frsp negative", ppc::fs(-1.0 - 0x1p-24), single_neg[rn]);
    bits("fnmadds single then negate", ppc::fnmadds(1.0, 1.0, 0x1p-24), single_pos[rn] ^ sign);
    bits("fnmsubs single then negate", ppc::fnmsubs(1.0, 1.0, -0x1p-24), single_pos[rn] ^ sign);
    bits("fused cancellation", ppc::fmadd(1.0 + 0x1p-27, 1.0 - 0x1p-27, -1.0), 0xbc90000000000000);
    bits("negative zero mul", ppc::fmul(-0.0, 2.0), sign);
    equal("fctiw +large", ppc::fctiw(0x1p50, false), 0xfff800007fffffff);
    equal("fctiw -large", ppc::fctiw(-0x1p50, false), 0xfff8000080000000);
    equal("fctiwz INT_MAX fractional", ppc::fctiw(2147483647.75, true), 0xfff800007fffffff);
    equal("fctiwz INT_MIN fractional", ppc::fctiw(-2147483648.75, true), 0xfff8000080000000);
    equal("fctiw negative zero marker", ppc::fctiw(-0.0, false), 0xfff8000100000000);
    equal("fctiwz negative zero marker", ppc::fctiw(-0.25, true), 0xfff8000100000000);
    const uint64_t cv[] = {0xfff8000000000002, 0xfff8000000000001,
                           0xfff8000000000002, 0xfff8000000000001};
    equal("fctiw RN", ppc::fctiw(1.5, false), cv[rn]);
  }
  ppc::set_fp_environment(0);
  bits("fnmadd exact cancellation signed zero", ppc::fnmadd(1, 1, -1), sign);
  ppc::set_fp_environment(2, ppc::FpProfile::UnlockedJit64);
  bits("legacy different directed fnmadd", ppc::fnmadd(1, 1, 0x1p-53), 0xbff0000000000000);
}
void non_ieee() {
  const double min_sub = ppc::bits_to_double(1);
  for (uint32_t rn = 0; rn < 4; ++rn) {
    ppc::set_fp_environment(rn | 4);
    bits("NI preserves input subnormal", ppc::fmul(min_sub, 0x1p1023), 0x3cc0000000000000);
    bits("NI preserves FMA input subnormal", ppc::fmadd(min_sub, 0x1p1023, 0), 0x3cc0000000000000);
    bits("NI flush positive output", ppc::fmul(0x1p-1022, 0.5), 0);
    bits("NI flush negative output", ppc::fmul(-0x1p-1022, 0.5), sign);
    bits("NI single before-round quirk", ppc::fs(ppc::bits_to_double(0x380fffffffffffff)), 0);
    bits("NI single before-round negative", ppc::fs(ppc::bits_to_double(0xb80fffffffffffff)), sign);
  }
  ppc::set_fp_environment(4, ppc::FpProfile::UnlockedJit64);
  bits("legacy NI flush input", ppc::fmul(min_sub, 0x1p1023), 0);
  ppc::set_fp_environment(0);
  bits("IEEE retains result subnormal", ppc::fmul(0x1p-1022, 0.5), 0x0008000000000000);
  bits("Force25Bit normalizes smallest subnormal", ppc::f25(min_sub), 1);
  bits("Force25Bit subnormal rounding", ppc::f25(ppc::bits_to_double(0x000000000fffffff)), 0x0000000010000000);
}
void nans_and_conversions() {
  ppc::set_fp_environment(0);
  const double a = ppc::bits_to_double(0xfff0000000000123);
  const double b = ppc::bits_to_double(0x7ff0000000000456);
  const double c = ppc::bits_to_double(0x7ff8000000000789);
  const double inf = ppc::bits_to_double(0x7ff0000000000000);
  bits("FMA NaN A first", ppc::fmadd(a, c, b), 0xfff8000000000123);
  bits("FMA NaN B before C", ppc::fmadd(1, c, b), 0x7ff8000000000456);
  bits("FMA NaN C", ppc::fmadd(1, c, 1), 0x7ff8000000000789);
  bits("FMSUB preserves B NaN sign", ppc::fmsub(1, 1, b), 0x7ff8000000000456);
  bits("FNMA preserves NaN sign", ppc::fnmadd(a, 1, 1), 0xfff8000000000123);
  bits("invalid mul canonical NaN", ppc::fmul(0, inf), 0x7ff8000000000000);
  bits("invalid FMA canonical NaN", ppc::fmadd(0, inf, 1), 0x7ff8000000000000);
  equal("fctiw NaN", ppc::fctiw(a, false), 0xfff8000080000000);
  equal("fctiw +inf", ppc::fctiw(inf, true), 0xfff800007fffffff);
  equal("fctiw -inf", ppc::fctiw(-inf, true), 0xfff8000080000000);
  const uint32_t single[] = {0, 0x80000000, 1, 0x007fffff, 0x00800000,
                             0x3f800000, 0x7f800000, 0xff800000, 0x7f800123, 0xffc00456};
  for (uint32_t value : single) {
    const double d = ppc::float_bits_to_double(value);
    equal("load/store float bit roundtrip", ppc::double_to_float_bits(d), value);
  }
  bits("load sNaN remains signaling", ppc::float_bits_to_double(0x7f800123), 0x7ff0002460000000);
  equal("stfs truncates stored fraction", ppc::double_to_float_bits(1.0 + 0x1.8p-23), 0x3f800001);
  equal("psq store flushes subnormal", ppc::double_to_float_bits_ftz(ppc::float_bits_to_double(1)), 0);
}
void estimates() {
  struct Case { uint64_t input, expected; };
  // Goldens from independently checked nativeC corpus, pinned FloatUtils.cpp.
  const Case rsqrt[] = {
    {0x3ff0000000000000, 0x3feffe8000000000}, {0x4000000000000000, 0x3fe69fa000000000},
    {0x4008000000000000, 0x3fe2794000000000}, {0x4010000000000000, 0x3fdffe8000000000},
    {0x3fb999999999999a, 0x40094cf320000000}, {1, 0x617ffe8000000000},
    {0x000fffffffffffff, 0x5fe000082c000000}, {0x0010000000000000, 0x5fdffe8000000000},
    {0x7fefffffffffffff, 0x1ff000082c000000}, {0, 0x7ff0000000000000},
    {0x8000000000000000, 0xfff0000000000000}, {0x7ff0000000000000, 0},
    {0xfff0000000000000, 0x7ff8000000000000}, {0xbff0000000000000, 0x7ff8000000000000},
    {0x8000000000000001, 0x7ff8000000000000}, {0x7ff8000000001234, 0x7ff8000000001234},
    {0xfff8000000001234, 0xfff8000000001234}, {0x7ff0000000001234, 0x7ff8000000001234},
    {0xfff0000000001234, 0xfff8000000001234},
  };
  for (uint32_t rn = 0; rn < 8; ++rn) {
    ppc::set_fp_environment(rn);
    for (auto v : rsqrt) bits("frsqrte table", ppc::frsqrte(ppc::bits_to_double(v.input)), v.expected);
    bits("fres one", ppc::fres(1), 0x3fefff0000000000);
    bits("fres two", ppc::fres(2), 0x3fdfff0000000000);
    bits("fres +zero", ppc::fres(0), 0x7ff0000000000000);
    bits("fres -zero", ppc::fres(-0.0), 0xfff0000000000000);
    bits("fres sNaN", ppc::fres(ppc::bits_to_double(0xfff0000000000123)), 0xfff8000000000123);
  }
}
void threads() {
  ppc::set_fp_environment(0);
  const int before = std::fegetround();
  { ppc::ScopedGuestFpEnvironment nested(3); }
  equal("scope restores host rounding", std::fegetround(), before);
  equal("scope restores guest fpscr", ppc::guest_fpscr(), 0);
  std::atomic<unsigned> ready{0}, wrong{0};
  std::vector<std::thread> workers;
  for (uint32_t rn = 0; rn < 4; ++rn) workers.emplace_back([&, rn] {
    const int original = std::fegetround();
    {
      ppc::ScopedGuestFpEnvironment fp(rn);
      ready.fetch_add(1);
      while (ready.load() < 4) std::this_thread::yield();
      for (unsigned i = 0; i < 256; ++i) {
        const uint64_t expected = rn == 2 ? 0x3ff0000000000001 : 0x3ff0000000000000;
        if (ppc::double_to_bits(ppc::fadd(1, 0x1p-53)) != expected || ppc::guest_fpscr() != rn)
          wrong.fetch_add(1);
      }
    }
    if (std::fegetround() != original) wrong.fetch_add(1);
  });
  for (auto& worker : workers) worker.join();
  equal("per-thread environment and restore", wrong.load(), 0);
}
}  // namespace
int main() {
  ppc::ScopedGuestFpEnvironment fp(0);
  integers(); rounding(); non_ieee(); nans_and_conversions(); estimates(); threads();
  std::printf("PPC numeric: %u checks, %u failures; FPSCR status/exception parity unverified\n", checks, failures);
  return failures ? 1 : 0;
}
