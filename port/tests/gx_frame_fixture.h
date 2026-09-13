// Authored capture-shaped fixture, not claimed to be a game recording.
#pragma once
#include "gx_core.h"
#include <array>
#include <bit>
namespace gx_test {
inline gx::Frame frame() {
  gx::Frame f;
  f.sequence = 7; f.time = 1.25;
  f.vertices.resize(4);
  gx::DrawCall d{};
  d.primitive = 0x90; d.first_vertex = 1; d.vertex_count = 3;
  d.components = gx::VB_HAS_POSMTXIDX | gx::VB_HAS_NRM0 | gx::VB_HAS_COL0 | gx::VB_HAS_COL1 |
      gx::VB_HAS_UV0 | (gx::VB_HAS_UV0 << 7) | gx::VB_HAS_TEXMTXIDX0 | (gx::VB_HAS_TEXMTXIDX0 << 7);
  for (unsigned i = 1; i <= 3; ++i) {
    auto& v = f.vertices[i];
    v.pos[0] = float(i); v.pos[1] = -2; v.pos[2] = 0.5f;
    v.nrm[2] = 1; v.posmtx = 3; v.texmtx[0] = 30; v.texmtx[7] = 57;
    v.col0[0] = 0x12; v.col0[1] = 0x34; v.col0[2] = 0x56; v.col0[3] = 0x78;
    v.col1[0] = 0x9a; v.col1[1] = 0xbc; v.col1[2] = 0xde; v.col1[3] = 0xf0;
    v.uv[0][0] = 0.25f; v.uv[0][1] = 0.75f;
    v.uv[7][0] = -1; v.uv[7][1] = 2;
  }
  d.bp.reg[gx::BP_GENMODE] = 1 | (1u << 4);
  d.xf_regs[0x09] = 1; d.xf_regs[0x3f] = 1;
  d.xf_regs[0x40] = 5u << 7; // XY texture source 0.
  d.matrix_index_a = 0;
  d.bp.reg[gx::BP_SCISSORTL] = (342u << 12) | 342;
  d.bp.reg[gx::BP_SCISSORBR] = (981u << 12) | 821;
  d.bp.reg[gx::BP_SCISSOROFFSET] = 171 | (171u << 10);
  d.bp.reg[gx::BP_BLENDMODE] = 0x18;
  d.bp.reg[gx::BP_ZMODE] = 0x17;
  d.bp.reg[gx::BP_ALPHACOMPARE] = 0x3f0000;
  d.bp.reg[gx::BP_TREF] = 0x40;
  d.bp.reg[gx::BP_TEV_COLOR_ENV] = 0x8f8f;
  d.bp.reg[gx::BP_SETDRAWDONE] = 2;
  d.bp.reg[gx::BP_PE_TOKEN_INT_ID] = 0x4321;
  d.bp.reg[gx::BP_TRIGGER_EFB_COPY] = 0xffffff;
  for (unsigned i = 0; i < 20; ++i) {
    d.posMatrices[i * 12] = d.posMatrices[i * 12 + 5] = d.posMatrices[i * 12 + 10] = 1;
    d.postMatrices[i * 12] = d.postMatrices[i * 12 + 5] = d.postMatrices[i * 12 + 10] = 1;
  }
  for (unsigned i = 0; i < 10; ++i)
    d.normalMatrices[i * 9] = d.normalMatrices[i * 9 + 4] = d.normalMatrices[i * 9 + 8] = 1;
  d.posMatrices[15] = 5.5f;
  const uint32_t light_color = 0x12345678;
  const auto color_bytes = std::bit_cast<std::array<uint8_t, 4>>(light_color);
  for (unsigned i = 0; i < 4; ++i) d.lights[0][12 + i] = color_bytes[i];
  const float viewport[]{320, -240, 16777215.f, 662, 582, 16777215.f};
  for (unsigned i = 0; i < 6; ++i) d.xf_regs[0x1a + i] = std::bit_cast<uint32_t>(viewport[i]);
  d.xf_regs[0x20] = std::bit_cast<uint32_t>(1.f);
  d.xf_regs[0x22] = std::bit_cast<uint32_t>(1.f);
  d.xf_regs[0x24] = std::bit_cast<uint32_t>(-1.f);
  d.xf_regs[0x25] = std::bit_cast<uint32_t>(-1.f);
  d.tev_colors[0][0] = -1; d.tev_colors[0][1] = 1023; d.tev_colors[0][2] = -1024; d.tev_colors[0][3] = 255;
  d.tev_kcolors[0][0] = 17; d.tev_kcolors[0][1] = 34; d.tev_kcolors[0][2] = 51; d.tev_kcolors[0][3] = 68;
  auto data = std::make_shared<gx::TextureSnapshot>();
  data->image.resize(32, 0x42); data->palette.resize(512, 0); data->hash = 42;
  auto& t = d.textures[0];
  t.used = true; t.addr = 0x1000; t.width = 8; t.height = 4; t.format = 9;
  t.mode0 = 4u << 5; t.tlut_format = 1; t.data = data;
  d.bp.reg[gx::BP_TX_SETMODE0] = t.mode0;
  d.bp.reg[gx::BP_TX_SETIMAGE0] = 7 | (3u << 10) | (9u << 20);
  f.draws.push_back(d);
  gx::EfbCopy c{};
  c.dest_addr = 0x100000; c.dest_stride = 1280; c.src_w = 640; c.src_h = 480;
  c.to_xfb = true; c.clear = true; c.y_scale = 1; c.clear_color = 0x10203040; c.clear_z = 0xffffff;
  gx::BPMemory copy_bp{};
  copy_bp.reg[gx::BP_BLENDMODE] = 0x18; copy_bp.reg[gx::BP_ZMODE] = 0x10;
  copy_bp.reg[gx::BP_COPYFILTER0] = (21u << 12) | (22u << 18);
  copy_bp.reg[gx::BP_COPYFILTER0 + 1] = 21;
  gx::capture_copy_state(c, copy_bp);
  f.copies.push_back(c);
  f.commands = {{gx::FrameCommand::Draw, 0}, {gx::FrameCommand::Copy, 0}};
  return f;
}
inline gx::EfbCopy texture_copy() {
  auto copy = frame().copies[0];
  copy.to_xfb = false; copy.clear = false; copy.format = 6;
  copy.src_w = 8; copy.src_h = 4; copy.dest_addr = 0x4000; copy.dest_stride = 128;
  copy.destination_before_copy.resize(128, 0x55);
  return copy;
}
} // namespace gx_test
