// SPDX-License-Identifier: GPL-2.0-or-later
#include "gx_msl.h"
#include <cstdio>
#include <stdexcept>

namespace gx::msl {
namespace {

void replace_all(std::string& s, const std::string& from, const std::string& to) {
  for (size_t pos = 0; (pos = s.find(from, pos)) != std::string::npos; pos += to.size()) s.replace(pos, from.size(), to);
}

// Replaces the text from `begin` through the first `end` after it (inclusive).
bool replace_span(std::string& s, const std::string& begin, const std::string& end, const std::string& with) {
  size_t a = s.find(begin);
  if (a == std::string::npos) return false;
  size_t b = s.find(end, a + begin.size());
  if (b == std::string::npos) return false;
  s.replace(a, b + end.size() - a, with);
  return true;
}

const char* kPrelude =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    // HLSL allows scalar limits for vector clamp; MSL does not.
    "inline int2 clamp(int2 x, int a, int b) { return clamp(x, int2(a), int2(b)); }\n"
    "inline int3 clamp(int3 x, int a, int b) { return clamp(x, int3(a), int3(b)); }\n"
    "inline int4 clamp(int4 x, int a, int b) { return clamp(x, int4(a), int4(b)); }\n"
    "inline float2 clamp(float2 x, float a, float b) { return clamp(x, float2(a), float2(b)); }\n"
    "inline float3 clamp(float3 x, float a, float b) { return clamp(x, float3(a), float3(b)); }\n"
    "inline float4 clamp(float4 x, float a, float b) { return clamp(x, float4(a), float4(b)); }\n"
    "inline float3 max(float a, float3 b) { return max(float3(a), b); }\n"
    "inline float3 max(float3 a, float b) { return max(a, float3(b)); }\n";

std::string vs_output_struct(uint32_t numTexGens) {
  std::string s = "struct VS_OUTPUT {\nfloat4 pos [[position]];\nfloat4 colors_0;\nfloat4 colors_1;\n";
  for (uint32_t i = 0; i < numTexGens; ++i) { char b[48]; std::snprintf(b, sizeof b, "float3 tex%u;\n", i); s += b; }
  s += "float4 clipPos;\n};\n";
  return s;
}

struct Field { const char* name; const char* type; int count; };
const Field kVsFields[] = {
    {"projection", "float4", 4}, {"depthparams", "float4", 0}, {"viewparams", "float4", 0}, {"materials", "float4", 4},
    {"lights", "float4", 40}, {"texmatrices", "float4", 24}, {"transformmatrices", "float4", 64}, {"normalmatrices", "float4", 32},
    {"posttransformmatrices", "float4", 64}, {"unjittered_projection", "float4", 4}, {"prev_projection", "float4", 4},
    {"prev_transformmatrices", "float4", 64}};
const Field kPsFields[] = {
    {"colors", "int4", 4}, {"kcolors", "int4", 4}, {"alpharef", "int4", 0}, {"texdims", "float4", 8}, {"zbias", "int4", 2},
    {"indtexscale", "int4", 2}, {"indtexmtx", "int4", 6}, {"fogcolor", "int4", 0}, {"fogi", "int4", 0}, {"fogf", "float4", 2},
    {"zslope", "float4", 0}, {"flags", "int4", 0}, {"efbscale", "float4", 0}, {"mvscale", "float4", 0}};

template <size_t N> std::string block_refs(const Field (&fields)[N]) {
  std::string s;
  for (const Field& f : fields) {
    char b[160];
    if (f.count) std::snprintf(b, sizeof b, "constant %s* %s = cb.%s;\n", f.type, f.name, f.name);
    else std::snprintf(b, sizeof b, "%s %s = cb.%s;\n", f.type, f.name, f.name);
    s += b;
  }
  return s;
}

}  // namespace

std::string vertex(const std::string& hlsl, uint32_t numTexGens) {
  std::string s = hlsl;
  replace_all(s, "cbuffer VSBlock : register(b0) {", "struct VSBlock {");
  if (!replace_span(s, "struct VS_OUTPUT {", "};\n", vs_output_struct(numTexGens)))
    throw std::runtime_error("msl: vertex shader has no VS_OUTPUT struct");
  std::string in =
      "struct VSIn {\nfloat3 rawpos [[attribute(0)]];\nfloat3 rawnorm0 [[attribute(1)]];\nfloat4 color0 [[attribute(2)]];\n"
      "float4 color1 [[attribute(3)]];\n";
  for (int i = 0; i < 8; ++i) { char b[64]; std::snprintf(b, sizeof b, "float2 rawtex%d [[attribute(%d)]];\n", i, 4 + i); in += b; }
  in += "uint4 blend_indices [[attribute(12)]];\nuint4 blend_indices2 [[attribute(13)]];\n};\n";
  std::string sig = "vertex VS_OUTPUT vs_main(VSIn in [[stage_in]], constant VSBlock& cb [[buffer(1)]]) {\n"
                    "float3 rawpos = in.rawpos; float3 rawnorm0 = in.rawnorm0; float4 color0 = in.color0; float4 color1 = in.color1;\n";
  for (int i = 0; i < 8; ++i) { char b[64]; std::snprintf(b, sizeof b, "float2 rawtex%d = in.rawtex%d;\n", i, i); sig += b; }
  sig += "uint4 blend_indices = in.blend_indices; uint4 blend_indices2 = in.blend_indices2;\n";
  sig += block_refs(kVsFields);
  if (!replace_span(s, "VS_OUTPUT main(", ") {\n", in + sig)) throw std::runtime_error("msl: vertex shader has no main");
  return kPrelude + s;
}

std::string pixel(const std::string& hlsl, uint32_t numTexGens, bool* early_z) {
  std::string s = hlsl;
  replace_all(s, "SamplerState samp[8] : register(s0);\nTexture2D Tex[8] : register(t0);\n", "");
  replace_all(s, "cbuffer PSBlock : register(b1) {", "struct PSBlock {");
  bool early = s.find("[earlydepthstencil]\n") != std::string::npos;
  replace_all(s, "[earlydepthstencil]\n", "");
  if (early_z) *early_z = early;
  std::string sig = std::string(early ? "[[early_fragment_tests]]\n" : "") +
      "fragment float4 ps_main(VS_OUTPUT in [[stage_in]], constant PSBlock& cb [[buffer(1)]], "
      "array<texture2d<float>, 8> Tex [[texture(0)]], array<sampler, 8> samp [[sampler(0)]]) {\n"
      "float4 ocol0 = float4(0.0);\nfloat4 rawpos = in.pos; float4 colors_0 = in.colors_0; float4 colors_1 = in.colors_1;\n";
  for (uint32_t i = 0; i < numTexGens; ++i) { char b[64]; std::snprintf(b, sizeof b, "float3 uv%u = in.tex%u;\n", i, i); sig += b; }
  sig += "float4 clipPos = in.clipPos;\n";
  sig += block_refs(kPsFields);
  if (!replace_span(s, "void main(", ") {\n", sig)) throw std::runtime_error("msl: pixel shader has no main");
  replace_all(s, ".Sample(", ".sample(");
  replace_all(s, "discard;", "discard_fragment();");
  replace_all(s, "remainder(", "iremainder(");
  // Integer/float mixes HLSL promotes implicitly.
  replace_all(s, "int3(sign(tin_a.rgb - tin_b.rgb - 0.5))", "int3(sign(float3(tin_a.rgb - tin_b.rgb) - 0.5))");
  replace_all(s, "sign(abs(tin_a.rgb - tin_b.rgb))", "int3(sign(float3(abs(tin_a.rgb - tin_b.rgb))))");
  const size_t last = s.rfind("}\n");
  if (last == std::string::npos) throw std::runtime_error("msl: pixel shader has no closing brace");
  s.replace(last, 2, "return ocol0;\n}\n");
  return kPrelude + vs_output_struct(numTexGens) + s;
}

}  // namespace gx::msl
