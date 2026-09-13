// Real CP932 adapters, exercised without identity, ENet, HTTP or a game image.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_net.h"
#include <cstdio>
#include <string>

namespace {
int failures = 0;
void check(bool condition, const char* message) {
  if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); ++failures; }
}
}
int main() {
  using namespace slippi;
  check(utf8_to_shiftjis("").empty(), "empty UTF-8");
  check(shiftjis_to_utf8("").empty(), "empty CP932");
  check(utf8_to_shiftjis("Slippi 123") == "Slippi 123", "ASCII round trip");
  const std::string japanese = "日本語";
  const std::string encoded("\x93\xFA\x96\x7B\x8C\xEA", 6);
  check(utf8_to_shiftjis(japanese) == encoded, "Japanese encoding matches CP932 fixture");
  check(shiftjis_to_utf8(encoded) == japanese, "Japanese decoding matches CP932 fixture");
  check(utf8_to_shiftjis("①") == std::string("\x87\x40", 2), "Windows CP932 extension is retained");
  check(shiftjis_to_utf8(std::string("\x87\x40", 2)) == "①", "Windows CP932 extension decodes");
  check(utf8_to_shiftjis("🙂") == "?", "unrepresentable code point is replaced once");
  check(truncate_length_char("A日本語B", 3) == "A日本", "game truncation counts code points");
  auto game = convert_string_for_game("A#B!", 4);
  check(game.size() == 9 && game.substr(0, 6) == std::string("A\x81\x94" "B\x81\x49", 6),
        "game punctuation uses the original full-width mapping");
  auto code = convert_connect_code_for_game("ABCD#123");
  check(code == std::string("ABCD\x81\x94" "123\0", 10), "connect code keeps its ten-byte EXI layout");
  check(convert_string_for_game("x", -1) == std::string(1, '\0'), "negative field length remains bounded");
  return failures ? 1 : 0;
}
