#include "gx_aurora_bridge.h"
#include "gx_frame_fixture.h"
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <map>

static void check(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "FAIL: %s\n", what); std::exit(1); }
}
template<class F> static void accepted(F f, const char* what) {
  try { f(); } catch (const gx::aurora_bridge::CoverageError& e) { std::fprintf(stderr, "%s: %s\n", what, e.what()); check(false, what); }
}
template<class F> static void rejected(F f, const char* needle) {
  try { f(); } catch (const gx::aurora_bridge::CoverageError& e) {
    check(std::string(e.what()).find(needle) != std::string::npos, e.what()); return;
  }
  check(false, "expected explicit coverage rejection");
}
struct Reader {
  const std::vector<uint8_t>& bytes; size_t at = 0;
  uint8_t u8() { check(at < bytes.size(), "wire truncated"); return bytes[at++]; }
  uint16_t u16() { auto a = u8(); return uint16_t(a << 8 | u8()); }
  uint32_t u32() { auto a = u16(); return uint32_t(a) << 16 | u16(); }
  float f32() { return std::bit_cast<float>(u32()); }
};
int main() {
  auto source = gx_test::frame();
  const auto original_state = source.draws[0].bp;
  const auto original_viewport = source.draws[0].xf_regs[0x1d];
  auto prepared = gx::aurora_bridge::prepare_frame(source);
  check(prepared.sequence == 7 && prepared.commands.size() == 2, "ordered frame ownership");
  check(prepared.draws[0].vertex_stride == 51 && prepared.draws[0].vertices.size() == 153, "canonical packed stride");
  Reader vertex{prepared.draws[0].vertices};
  for (unsigned i = 1; i <= 3; ++i) {
    check(vertex.u8() == 3 && vertex.u8() == 30 && vertex.u8() == 57, "GX matrix attributes precede position");
    check(vertex.f32() == float(i) && vertex.f32() == -2 && vertex.f32() == 0.5f, "position offset/endianness");
    check(vertex.f32() == 0 && vertex.f32() == 0 && vertex.f32() == 1, "normal direct encoding");
    check(vertex.u32() == 0x12345678 && vertex.u32() == 0x9abcdef0, "RGBA byte order");
    check(vertex.f32() == .25f && vertex.f32() == .75f && vertex.f32() == -1 && vertex.f32() == 2, "noncontiguous UV attributes");
  }
  std::map<uint8_t, uint32_t> cp;
  std::map<uint16_t, std::vector<uint32_t>> xf;
  std::vector<uint32_t> tev;
  Reader state{prepared.draws[0].state};
  while (state.at < state.bytes.size()) {
    const auto op = state.u8();
    if (op == 0x61) {
      const auto word = state.u32(); const auto reg = word >> 24;
      check(reg != 0x45 && reg != 0x47 && reg != 0x48 && reg != 0x52 && reg != 0x65, "no replayed PE IRQ/copy/TLUT side effects");
      if (reg == 0xe0 || reg == 0xe1) tev.push_back(word & 0xffffff);
      if (reg == gx::BP_SCISSORTL) check((word & 0xffffff) == ((342u << 12) | 342), "scissor guest offset normalized");
    } else if (op == 0x08) { const auto reg = state.u8(); cp[reg] = state.u32(); }
    else if (op == 0x10) {
      const auto count = unsigned(state.u16()) + 1; const auto address = state.u16();
      for (unsigned i = 0; i < count; ++i) xf[address].push_back(state.u32());
    } else check(false, "unexpected reconstructed state opcode");
  }
  check(cp[0x50] == (0x103u | (1u << 9) | (1u << 11) | (1u << 13) | (1u << 15)), "direct VCD low layout");
  check(cp[0x60] == (1u | (1u << 14)), "direct VCD high layout");
  check((cp[0x70] & 15) == 9 && ((cp[0x70] >> 14) & 7) == 5 && ((cp[0x80] >> 27) & 15) == 9,
        "VAT uses F32 XYZ, RGBA8 and F32 ST");
  check(tev.size() == 4 && tev[0] == (0x7ffu | (255u << 12)) && tev[1] == (0x400u | (1023u << 12)) &&
        tev[2] == (0x800000u | 17u | (68u << 12)) && tev[3] == (0x800000u | 51u | (34u << 12)),
        "signed TEV and independent konst banks both restored");
  check(xf[12][3] == std::bit_cast<uint32_t>(5.5f) && xf[0x600][3] == 0x12345678, "matrix and host-endian light capture conversion");
  check(xf[0x101a][3] == std::bit_cast<uint32_t>(660.f) && xf[0x101a][4] == std::bit_cast<uint32_t>(580.f), "Aurora viewport origin-bias mapping");
  check(xf[0x1050][0] == 61 && xf[0x1050][7] == 61, "disabled dual transform maps to post identity");
  check(source.draws[0].bp.reg[0x52] == original_state.reg[0x52] && source.draws[0].xf_regs[0x1d] == original_viewport,
        "conversion never edits source capture");
  source.clear();
  check(prepared.draws[0].textures[0].data->image[0] == 0x42 && prepared.draws[0].textures[0].data->palette.size() == 512,
        "immutable image and palette survive source-frame recycling");

  auto bad = gx_test::frame(); bad.draws[0].components |= gx::VB_UNCAPTURED_NBT;
  accepted([&] { gx::aurora_bridge::prepare_frame(bad); }, "uncaptured NBT renders with its normal");
  bad = gx_test::frame(); bad.vertices[1].texmtx[0] = 60;
  accepted([&] { gx::aurora_bridge::prepare_frame(bad); }, "dynamic identity texture matrix warns only");
  bad = gx_test::frame(); bad.draws[0].first_vertex = UINT32_MAX;
  check(gx::aurora_bridge::prepare_frame(bad).draws[0].vertex_count == 0, "an invalid draw is skipped, not the frame");
  bad = gx_test::frame(); bad.copies[0].has_copy_state = false;
  rejected([&] { gx::aurora_bridge::prepare_frame(bad); }, "copy-time BP");
  bad = gx_test::frame(); bad.copies[0].blendmode = 8;
  accepted([&] { gx::aurora_bridge::prepare_frame(bad); }, "non-clearing XFB copy still presents");
  bad = gx_test::frame(); bad.copies[0].filter0 |= 8;
  accepted([&] { gx::aurora_bridge::prepare_frame(bad); }, "copy filter is ignored, not rejected");
  bad = gx_test::frame(); bad.copies[0].filter0 = (1u << 12) | (62u << 18); bad.copies[0].filter1 = 1;
  accepted([&] { gx::aurora_bridge::prepare_frame(bad); }, "copy filter is ignored, not rejected");
  bad = gx_test::frame(); bad.commands.push_back({gx::FrameCommand::Draw, 0});
  rejected([&] { gx::aurora_bridge::prepare_frame(bad); }, "final command");
  gx::BPMemory changing{};
  changing.reg[gx::BP_BLENDMODE] = 0x18; changing.reg[gx::BP_ZMODE] = 0x10;
  gx::EfbCopy copy{}; gx::capture_copy_state(copy, changing);
  changing.reg[gx::BP_BLENDMODE] = 0;
  check(copy.blendmode == 0x18 && copy.zmode == 0x10 && copy.has_copy_state, "capture uses copy-time masks, independent of later BP mutation");

  // Same pure history seam is used by the actual GPU adapter. A copy followed
  // by a sample is valid; CPU mutation before its first-ever sample is not.
  gx::aurora_bridge::PreparedFrame ordered;
  ordered.copies.push_back(gx_test::texture_copy());
  ordered.draws.emplace_back();
  auto& t = ordered.draws[0].textures[0];
  t.used = true; t.addr = 0x4000; t.width = 8; t.height = 4; t.format = 6;
  auto data = std::make_shared<gx::TextureSnapshot>();
  data->image = ordered.copies[0].destination_before_copy; t.data = data;
  ordered.commands = {{gx::FrameCommand::Copy, 0}, {gx::FrameCommand::Draw, 0}};
  auto history = gx::aurora_bridge::advance_copy_history(ordered, {});
  check(history.size() == 1 && history.at(0x4000).bytes == 128, "copy-before-draw retains exact alias interval");
  data->image[0] ^= 1;
  accepted([&] { gx::aurora_bridge::advance_copy_history(ordered, {}); }, "CPU-modified copy destination warns only");
  data->image[0] ^= 1;
  auto shrink = ordered; shrink.commands.resize(1); shrink.copies[0].src_w = 4; shrink.copies[0].dest_stride = 64;
  accepted([&] { gx::aurora_bridge::advance_copy_history(shrink, history); }, "shape change warns only");
  auto overlap = ordered; overlap.commands.resize(1); overlap.copies[0].dest_addr += 32;
  accepted([&] { gx::aurora_bridge::advance_copy_history(overlap, history); }, "overlap warns only");
  ordered.commands = {{gx::FrameCommand::Draw, 0}};
  check(gx::aurora_bridge::advance_copy_history(ordered, history).size() == 1, "cross-frame copy identity survives");
  check(gx::aurora_bridge::advance_copy_history(ordered, {}).empty(), "epoch-cleared history does not reuse copy identity");
  std::puts("Aurora conversion: vertex/VAT endian layout, BP/XF/TEV, immutable textures, copy masks/filter/order/alias guards passed");
}
