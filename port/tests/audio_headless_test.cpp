// SPDX-License-Identifier: GPL-2.0-or-later
#include "audio.h"
#include "audio_headless.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <unistd.h>

static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
int main() {
  std::string temporary = (std::filesystem::temp_directory_path() / "melee-audio-test-XXXXXX").string();
  std::vector<char> path(temporary.begin(), temporary.end()); path.push_back(0);
  require(::mkdtemp(path.data()) != nullptr, "create isolated audio test directory");
  std::filesystem::path dir(path.data()), wav = dir / "dma.wav";
  require(!host::audio_open(0, nullptr, true), "headless sink rejects a device request");
  require(host::audio_open(0, wav.string().c_str(), false), "open WAV sink");
  std::array<uint8_t, 1280> dma{};
  dma[0] = 0x12; dma[1] = 0x34; dma[2] = 0xfe; dma[3] = 0xdc;
  host::audio_push(dma.data(), dma.size());
  require(host::audio_pushed_frames() == 320, "AI DMA frame count");
  host::audio_close();
  require(host::headless_audio_output_ok(), "WAV writes and finalization");
  std::ifstream file(wav, std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
  require(bytes.size() == 44 + dma.size(), "WAV size");
  require(std::string(bytes.begin(), bytes.begin() + 4) == "RIFF", "WAV RIFF header");
  require(bytes[40] == 0 && bytes[41] == 5 && bytes[42] == 0 && bytes[43] == 0, "WAV little-endian data length");
  require(bytes[44] == 0xdc && bytes[45] == 0xfe && bytes[46] == 0x34 && bytes[47] == 0x12, "R/L big-endian DMA becomes L/R little-endian WAV");
  require(!host::audio_open(0, wav.string().c_str(), false), "existing WAV is not overwritten");
  require(host::audio_open(0, nullptr, false), "discard sink remains active without a file");
  host::audio_push(dma.data(), dma.size());
  require(host::audio_pushed_frames() == 320, "discard sink counts AI DMA");
  host::audio_close();
  std::filesystem::remove(wav);
  std::filesystem::remove(dir);
}
