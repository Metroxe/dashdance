// Image identity and bounded disc-name matching must agree across host platforms.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "platform_file.h"
#include "sha1.h"
#include "sha256.h"
#include <cstdlib>
#include <string>

static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
static std::string digest(const std::string& input) {
  auto hash = host::sha1(reinterpret_cast<const uint8_t*>(input.data()), input.size());
  std::string result;
  for (uint8_t byte : hash) { result += "0123456789abcdef"[byte >> 4]; result += "0123456789abcdef"[byte & 15]; }
  return result;
}
int main() {
  auto sha256 = [](const std::string& bytes) { return host::memory_sha256(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size()); };
  require(sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 empty vector");
  require(sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 short vector");
  require(sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256 two-block padding vector");
  require(sha256(std::string(1000000, 'a')) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "SHA-256 million-byte vector");
  require(sha256("abc") != sha256("abd"), "loaded-byte mutation changes SHA-256");
  require(digest("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "SHA-1 empty vector");
  require(digest("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 short vector");
  require(digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
          "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "SHA-1 two-block padding vector");
  require(digest(std::string(1000000, 'a')) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f", "SHA-1 million-byte vector");
  const char name[] = "PlMr.dat";
  require(host::fst_name_equal(name, sizeof name, "PlMr.dat", false), "exact FST name");
  require(!host::fst_name_equal(name, sizeof name, "plmr.dat", false), "case-sensitive FST pass");
  require(host::fst_name_equal(name, sizeof name, "plmr.dat", true), "case-insensitive FST pass");
  require(!host::fst_name_equal(name, sizeof name - 1, "PlMr.dat", false), "unterminated FST name rejected");
  require(!host::fst_name_equal(name, sizeof name, "PlMr", true), "FST prefix rejected");
  require(!host::fst_name_equal(name, sizeof name, "PlMr.dat.extra", true), "FST suffix rejected");
  FILE* file = std::tmpfile();
  require(file != nullptr, "temporary seek test file");
  require(host::seek_file(file, 0), "seek to beginning");
  require(host::seek_file(file, UINT64_C(0x100000001)), "64-bit seek past 4 GiB");
  require(!host::seek_file(file, UINT64_MAX), "unrepresentable seek rejected");
  std::fclose(file);
}
