// Module identity covers the bytes resident in the recorded guest span.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "sha256.h"
#include <array>
#include <cstdio>
#include <cstring>

int main() {
  int failures = 0;
  auto check = [&](bool ok, const char* what) {
    if (!ok) { ++failures; std::fprintf(stderr, "FAIL: %s\n", what); }
  };
  std::array<uint8_t, 3> source{'a', 'b', 'c'};
  std::array<uint8_t, 7> guest{'P', 'P', 0, 0, 0, 'S', 'S'};
  constexpr size_t offset = 2, loaded = 3;
  std::memcpy(guest.data() + offset, source.data(), loaded);
  const auto original = host::memory_sha256(guest.data() + offset, loaded);
  check(original == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "post-DMA bytes match the standard SHA-256 abc vector");

  source[0] = 'z';
  check(host::memory_sha256(guest.data() + offset, loaded) == original,
        "changing the source after DMA cannot change loaded guest identity");
  guest[0] ^= 0xFF;
  guest.back() ^= 0xFF;
  check(host::memory_sha256(guest.data() + offset, loaded) == original,
        "bytes outside the recorded range do not affect its digest");
  check(host::memory_sha256(guest.data() + offset, loaded - 1) != original,
        "a truncated DMA range has a different identity");
  guest[offset + 1] ^= 1;
  check(host::memory_sha256(guest.data() + offset, loaded) != original,
        "a change to the actual loaded guest bytes changes its identity");
  check(host::memory_sha256(nullptr, 0) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty byte range uses the standard SHA-256 vector");
  return failures ? 1 : 0;
}
