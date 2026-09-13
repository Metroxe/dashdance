// Turns the generated HLSL GX shaders into Metal Shading Language. The generator's
// output is constrained (see gx_shader.cpp), so a targeted rewrite of its known
// constructs is exact; anything outside that set fails Metal compilation loudly.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <string>

namespace gx::msl {
// MSL source for the vertex function `vs_main` (VSIn [[stage_in]], VSBlock at buffer(1)).
std::string vertex(const std::string& hlsl, uint32_t numTexGens);
// MSL source for the fragment function `ps_main` (VS_OUTPUT [[stage_in]], PSBlock at
// buffer(1), textures 0-7, samplers 0-7). `early_z` receives whether the HLSL asked for
// forced early depth so the caller can build the pipeline accordingly.
std::string pixel(const std::string& hlsl, uint32_t numTexGens, bool* early_z);
}  // namespace gx::msl
