// SPDX-License-Identifier: GPL-2.0-or-later
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <TargetConditionals.h>
#include "gx_metal.h"
#include "gx_msl.h"
#include "gx_regs.h"
#include "gx_shader.h"
#include "gx_texture.h"
#include "host.h"
#include <CoreText/CoreText.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <unordered_map>
#include <vector>

namespace gx {
namespace {

constexpr int FRAME_SLOTS = 3;
constexpr size_t VERTEX_RING = 24u << 20, INDEX_RING = 12u << 20, CONSTANT_RING = 32u << 20;

struct Ring {
  id<MTLBuffer> buffer = nil;
  size_t size = 0, used = 0;
  void init(id<MTLDevice> device, size_t bytes) {
    buffer = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    size = bytes; used = 0;
  }
  bool alloc(size_t bytes, size_t align, uint8_t** cpu, size_t* offset) {
    size_t off = (used + align - 1) & ~(align - 1);
    if (off + bytes > size) return false;
    *cpu = (uint8_t*)buffer.contents + off; *offset = off; used = off + bytes;
    return true;
  }
};

struct PsoKey {
  uint64_t vs, ps;
  uint32_t blend, zmode, pixel_format, topology;
  bool operator==(const PsoKey& o) const {
    return vs == o.vs && ps == o.ps && blend == o.blend && zmode == o.zmode && pixel_format == o.pixel_format && topology == o.topology;
  }
};
struct PsoKeyHash { size_t operator()(const PsoKey& k) const {
  const uint64_t f[] = {k.vs, k.ps, k.blend, k.zmode, k.pixel_format, k.topology};
  return (size_t)hash_bytes(f, sizeof f);
} };

struct TextureEntry { id<MTLTexture> texture = nil; uint32_t width = 0, height = 0, levels = 1; uint64_t last_used = 0; };
struct Pipeline { id<MTLRenderPipelineState> state = nil; };

struct BlitConstants { float rect[4]; float sharp[4]; float box[4]; };
struct ClearConstants { float color[4]; float depth; float pad[3]; };

const char* kBlitSource = R"(
#include <metal_stdlib>
using namespace metal;
struct C { float4 rect; float4 sharp; float4 box; };
struct O { float4 pos [[position]]; float2 uv; };
vertex O blit_vs(uint id [[vertex_id]], constant C& c [[buffer(0)]]) {
  O o; float2 p = float2((id << 1) & 2, id & 2);
  o.pos = float4(p * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = p * c.rect.xy + c.rect.zw; return o;
}
float4 downsample(texture2d<float> src, sampler samp, constant C& c, float2 uv) {
  int nx = int(c.box.x), ny = int(c.box.y);
  if (nx <= 1 && ny <= 1) return src.sample(samp, uv);
  float2 foot = c.sharp.xy * float2(nx, ny);
  float4 acc = float4(0);
  for (int y = 0; y < ny; ++y)
    for (int x = 0; x < nx; ++x)
      acc += src.sample(samp, uv + (float2(x, y) + 0.5) / float2(nx, ny) * foot - 0.5 * foot);
  return acc / float(nx * ny);
}
fragment float4 blit_ps(O i [[stage_in]], constant C& c [[buffer(0)]], texture2d<float> src [[texture(0)]], sampler samp [[sampler(0)]]) {
  float4 col = downsample(src, samp, c, i.uv);
  if (c.sharp.z <= 0.0) return col;
  float2 step = c.sharp.xy * max(c.box.xy, float2(1.0));
  float3 n = src.sample(samp, i.uv + float2(0, -step.y)).rgb, s = src.sample(samp, i.uv + float2(0, step.y)).rgb;
  float3 w = src.sample(samp, i.uv + float2(-step.x, 0)).rgb, e = src.sample(samp, i.uv + float2(step.x, 0)).rgb;
  float3 mn = min(min(min(n, s), min(w, e)), col.rgb), mx = max(max(max(n, s), max(w, e)), col.rgb);
  float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, float3(1e-4))));
  float peak = -1.0 / mix(8.0, 5.0, saturate(c.sharp.z));
  float3 wgt = amp * peak;
  float3 r = (col.rgb + (n + s + w + e) * wgt) / (1.0 + 4.0 * wgt);
  return float4(saturate(r), col.a);
}
struct ClearC { float4 color; float depth; float pad0, pad1, pad2; };
struct ClearO { float4 pos [[position]]; };
vertex ClearO clear_vs(uint id [[vertex_id]], constant ClearC& c [[buffer(0)]]) {
  ClearO o; float2 p = float2((id << 1) & 2, id & 2);
  o.pos = float4(p * float2(2, -2) + float2(-1, 1), c.depth, 1); return o;
}
fragment float4 clear_ps(ClearO i [[stage_in]], constant ClearC& c [[buffer(0)]]) { return c.color; }

// Controller overlay: one rounded-rect / circle / ring per instance, signed-distance
// anti-aliased, labels sampled from a CoreText atlas (system font).
struct OvShape { float4 rect; float4 color; float4 params; uint label; float label_w; float label_h; float pad; };
struct OvC { float2 size; float alpha; float pad; float4 labels[16]; };
struct OvO { float4 pos [[position]]; float2 px; uint id [[flat]]; };
vertex OvO overlay_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant OvShape* shapes [[buffer(0)]], constant OvC& c [[buffer(1)]]) {
  float4 r = shapes[iid].rect + float4(-2, -2, 2, 2);
  float2 p = float2((vid == 1 || vid == 2 || vid == 4) ? r.z : r.x, (vid == 2 || vid == 4 || vid == 5) ? r.w : r.y);
  OvO o; o.px = p; o.id = iid;
  o.pos = float4(p / c.size * float2(2, -2) + float2(-1, 1), 0, 1);
  return o;
}
float label_coverage(OvShape s, constant OvC& c, float2 p, texture2d<float> atlas, sampler samp) {
  if (s.label == 0u || s.label >= 16u) return 0.0;
  float4 l = c.labels[s.label];   // atlas rect in texels: x, y, w, h
  if (l.w <= 0.0) return 0.0;
  float aspect = l.z / l.w;
  float lw = min(s.label_w, s.label_h * aspect), lh = lw / aspect;
  float2 centre = (s.rect.xy + s.rect.zw) * 0.5;
  float2 q = (p - centre) / float2(lw, lh) + 0.5;
  if (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0) return 0.0;
  float2 texel = l.xy + q * l.zw;
  return atlas.sample(samp, texel / float2(atlas.get_width(), atlas.get_height())).r;
}
fragment float4 overlay_ps(OvO i [[stage_in]], constant OvShape* shapes [[buffer(0)]], constant OvC& c [[buffer(1)]],
                           texture2d<float> atlas [[texture(0)]], sampler samp [[sampler(0)]]) {
  OvShape s = shapes[i.id];
  float2 half_size = (s.rect.zw - s.rect.xy) * 0.5, centre = (s.rect.xy + s.rect.zw) * 0.5;
  float corner = min(s.params.x, min(half_size.x, half_size.y));
  float2 q = abs(i.px - centre) - (half_size - corner);
  float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
  float fill = 1.0 - smoothstep(-0.75, 0.75, d);
  float label = label_coverage(s, c, i.px, atlas, samp) * fill;
  float3 col = mix(s.color.rgb, float3(1.0), label);
  float a = max(fill * s.color.a, label * 0.95);
  return float4(col * a * c.alpha, a * c.alpha);
}
)";

class MetalBackend final : public Backend {
 public:
  MetalBackend(CAMetalLayer* layer, int w, int h, const MetalOptions& o) : layer_(layer), opts_(o), client_w_(w), client_h_(h) { init(); }
  ~MetalBackend() override { wait_idle(); }
  void submit_frame(const Frame& frame) override { submit(frame, nullptr); }
  void submit_frame(const Frame& frame, const DrawMatrices* overrides) override { submit(frame, overrides); }
  void set_skip_present(bool skip) override { skip_present_ = skip; }
  void resize(int w, int h) {
    wait_idle();
    client_w_ = std::max(w, 1); client_h_ = std::max(h, 1);
    layer_.drawableSize = CGSizeMake(client_w_, client_h_);
    if (opts_.efb_scale == 0 && pick_scale() != scale_) { efb_copies_.clear(); create_efb(); }
  }
  void set_options(const MetalOptions& o) {
    const bool rescale = o.efb_scale != opts_.efb_scale || o.ssaa != opts_.ssaa || o.widescreen != opts_.widescreen;
    const bool resample = o.anisotropy != opts_.anisotropy;
    opts_ = o;
#if TARGET_OS_OSX
    layer_.displaySyncEnabled = opts_.vsync;
#endif
    if (rescale && pick_scale() != scale_) { wait_idle(); efb_copies_.clear(); create_efb(); }
    if (resample) { wait_idle(); samplers_.clear(); }
  }
  uint64_t frames_presented() const { return frames_presented_; }
  void set_overlay(OverlayProvider provider) { overlay_ = std::move(provider); }

 private:
  // ---- setup
  void init() {
    device_ = layer_.device ?: MTLCreateSystemDefaultDevice();
    if (!device_) host::die("metal: no GPU device");
    layer_.device = device_;
    layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer_.framebufferOnly = YES;
    layer_.drawableSize = CGSizeMake(client_w_, client_h_);
#if TARGET_OS_OSX
    layer_.displaySyncEnabled = opts_.vsync;
#endif
    queue_ = [device_ newCommandQueue];
    frame_semaphore_ = dispatch_semaphore_create(FRAME_SLOTS);
    for (int i = 0; i < FRAME_SLOTS; ++i) {
      vertex_ring_[i].init(device_, VERTEX_RING);
      index_ring_[i].init(device_, INDEX_RING);
      constant_ring_[i].init(device_, CONSTANT_RING);
    }
    vertex_descriptor_ = [MTLVertexDescriptor vertexDescriptor];
    auto attr = [&](int index, MTLVertexFormat format, int offset) {
      vertex_descriptor_.attributes[index].format = format;
      vertex_descriptor_.attributes[index].offset = offset;
      vertex_descriptor_.attributes[index].bufferIndex = 0;
    };
    attr(0, MTLVertexFormatFloat3, 0);
    attr(1, MTLVertexFormatFloat3, 12);
    attr(2, MTLVertexFormatUChar4Normalized, 24);
    attr(3, MTLVertexFormatUChar4Normalized, 28);
    for (int i = 0; i < 8; ++i) attr(4 + i, MTLVertexFormatFloat2, 32 + 8 * i);
    attr(12, MTLVertexFormatUChar4, 96);
    attr(13, MTLVertexFormatUChar4, 100);
    vertex_descriptor_.layouts[0].stride = sizeof(Vertex);
    vertex_descriptor_.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    create_blit_pipelines();
    create_efb();
    host::log("metal: %s", device_.name.UTF8String);
  }

  void create_blit_pipelines() {
    NSError* error = nil;
    MTLCompileOptions* options = [MTLCompileOptions new];
    id<MTLLibrary> lib = [device_ newLibraryWithSource:[NSString stringWithUTF8String:kBlitSource] options:options error:&error];
    if (!lib) host::die("metal: blit shaders: %s", error.localizedDescription.UTF8String);
    auto make = [&](const char* vs, const char* ps, MTLPixelFormat color, bool depth, bool blend) {
      MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
      d.vertexFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:vs]];
      d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithUTF8String:ps]];
      d.colorAttachments[0].pixelFormat = color;
      if (blend) {   // premultiplied alpha
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
      }
      if (depth) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
      id<MTLRenderPipelineState> state = [device_ newRenderPipelineStateWithDescriptor:d error:&error];
      if (!state) host::die("metal: pipeline %s/%s: %s", vs, ps, error.localizedDescription.UTF8String);
      return state;
    };
    blit_present_ = make("blit_vs", "blit_ps", MTLPixelFormatBGRA8Unorm, false, false);
    blit_copy_ = make("blit_vs", "blit_ps", MTLPixelFormatRGBA8Unorm, false, false);
    clear_pipeline_ = make("clear_vs", "clear_ps", MTLPixelFormatRGBA8Unorm, true, false);
    overlay_pipeline_ = make("overlay_vs", "overlay_ps", MTLPixelFormatBGRA8Unorm, false, true);
    create_overlay_atlas();
    MTLDepthStencilDescriptor* ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways; ds.depthWriteEnabled = YES;
    clear_depth_state_ = [device_ newDepthStencilStateWithDescriptor:ds];
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear; sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge; sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    blit_sampler_ = [device_ newSamplerStateWithDescriptor:sd];
  }

  float output_aspect() const { return opts_.widescreen ? 16.0f / 9.0f : 4.0f / 3.0f; }
  int pick_scale() const {
    constexpr int max_scale = 16384 / EFB_WIDTH;
    const int ssaa = std::clamp(opts_.ssaa, 1, 2);
    if (opts_.efb_scale > 0) return std::clamp(opts_.efb_scale * ssaa, 1, max_scale);
    float ww = (float)std::max(client_w_, 1), wh = (float)std::max(client_h_, 1);
    float aspect = output_aspect();
    float vw = ww, vh = ww / aspect;
    if (vh > wh) { vh = wh; vw = wh * aspect; }
    int s = std::max((int)std::ceil(vw / (480.0f * aspect)), (int)std::ceil(vh / 480.0f));
    return std::clamp(s * ssaa, 1, max_scale);
  }

  void create_efb() {
    scale_ = pick_scale();
    efb_w_ = EFB_WIDTH * scale_; efb_h_ = EFB_HEIGHT * scale_;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:efb_w_ height:efb_h_ mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    efb_color_ = [device_ newTextureWithDescriptor:td];
    MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:efb_w_ height:efb_h_ mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    efb_depth_ = [device_ newTextureWithDescriptor:dd];
    efb_needs_clear_ = true;
    host::log("metal: internal resolution %dx%d (EFB x%d, drawable %dx%d)", efb_w_, efb_h_, scale_, client_w_, client_h_);
  }

  void wait_idle() {
    for (int i = 0; i < FRAME_SLOTS; ++i) dispatch_semaphore_wait(frame_semaphore_, DISPATCH_TIME_FOREVER);
    for (int i = 0; i < FRAME_SLOTS; ++i) dispatch_semaphore_signal(frame_semaphore_);
  }

  // ---- render passes
  void ensure_efb_pass() {
    if (encoder_) return;
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = efb_color_;
    rp.colorAttachments[0].loadAction = efb_needs_clear_ ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = efb_depth_;
    rp.depthAttachment.loadAction = efb_needs_clear_ ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.depthAttachment.clearDepth = 0.0;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    efb_needs_clear_ = false;
    encoder_ = [command_ renderCommandEncoderWithDescriptor:rp];
    [encoder_ setFrontFacingWinding:MTLWindingClockwise];
    [encoder_ setVertexBuffer:vertex_ring_[slot_].buffer offset:0 atIndex:0];
    bound_pipeline_ = nil; bound_depth_ = nil; bound_cull_ = -1;
  }
  void end_pass() {
    if (!encoder_) return;
    [encoder_ endEncoding];
    encoder_ = nil;
  }

  // ---- pipelines
  id<MTLDepthStencilState> depth_state(uint32_t zmode) {
    auto it = depth_states_.find(zmode);
    if (it != depth_states_.end()) return it->second;
    static const MTLCompareFunction cmp[] = {MTLCompareFunctionNever, MTLCompareFunctionGreater, MTLCompareFunctionEqual, MTLCompareFunctionGreaterEqual,
                                             MTLCompareFunctionLess, MTLCompareFunctionNotEqual, MTLCompareFunctionLessEqual, MTLCompareFunctionAlways};
    MTLDepthStencilDescriptor* d = [MTLDepthStencilDescriptor new];
    const bool enable = bits(zmode, 0, 1);
    d.depthCompareFunction = enable ? cmp[bits(zmode, 1, 3)] : MTLCompareFunctionAlways;
    d.depthWriteEnabled = enable && bits(zmode, 4, 1);
    id<MTLDepthStencilState> state = [device_ newDepthStencilStateWithDescriptor:d];
    depth_states_[zmode] = state;
    return state;
  }

  id<MTLRenderPipelineState> get_pipeline(const DrawCall& dc, MTLPrimitiveType prim) {
    if (dc.cached_pipeline && dc.cached_pipeline_owner == backend_id_) return (__bridge id<MTLRenderPipelineState>)dc.cached_pipeline;
    VSUid vsu = make_vs_uid(dc);
    PSUid psu = make_ps_uid(dc);
    const uint64_t vh = vsu.hash(), ph = psu.hash();
    const uint32_t topology = prim == MTLPrimitiveTypeLine ? 1 : 0;
    PsoKey key{vh, ph, dc.bp.blendmode() & 0xFFFF, dc.bp.zmode() & 0x1F, dc.bp.zcontrol() & 7, topology};
    auto it = pipelines_.find(key);
    if (it != pipelines_.end()) {
      dc.cached_pipeline_owner = backend_id_; dc.cached_pipeline = (__bridge void*)it->second;
      return it->second;
    }
    id<MTLFunction> vs = vertex_function(vh, vsu);
    id<MTLFunction> ps = pixel_function(ph, psu);
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs; d.fragmentFunction = ps;
    d.vertexDescriptor = vertex_descriptor_;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    d.inputPrimitiveTopology = topology ? MTLPrimitiveTopologyClassLine : MTLPrimitiveTopologyClassTriangle;
    auto* ca = d.colorAttachments[0];
    ca.pixelFormat = MTLPixelFormatRGBA8Unorm;
    const uint32_t bm = key.blend;
    const bool alpha_in_efb = key.pixel_format == 1;
    static const MTLBlendFactor src_factors[] = {MTLBlendFactorZero, MTLBlendFactorOne, MTLBlendFactorDestinationColor, MTLBlendFactorOneMinusDestinationColor,
                                                 MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha, MTLBlendFactorDestinationAlpha, MTLBlendFactorOneMinusDestinationAlpha};
    static const MTLBlendFactor dst_factors[] = {MTLBlendFactorZero, MTLBlendFactorOne, MTLBlendFactorSourceColor, MTLBlendFactorOneMinusSourceColor,
                                                 MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha, MTLBlendFactorDestinationAlpha, MTLBlendFactorOneMinusDestinationAlpha};
    MTLBlendFactor s = src_factors[bits(bm, 8, 3)], dst = dst_factors[bits(bm, 5, 3)];
    if (!alpha_in_efb) {
      if (s == MTLBlendFactorDestinationAlpha) s = MTLBlendFactorOne; if (s == MTLBlendFactorOneMinusDestinationAlpha) s = MTLBlendFactorZero;
      if (dst == MTLBlendFactorDestinationAlpha) dst = MTLBlendFactorOne; if (dst == MTLBlendFactorOneMinusDestinationAlpha) dst = MTLBlendFactorZero;
    }
    ca.blendingEnabled = bits(bm, 0, 1);
    ca.sourceRGBBlendFactor = s; ca.destinationRGBBlendFactor = dst;
    ca.rgbBlendOperation = bits(bm, 11, 1) ? MTLBlendOperationReverseSubtract : MTLBlendOperationAdd;
    ca.sourceAlphaBlendFactor = MTLBlendFactorOne; ca.destinationAlphaBlendFactor = MTLBlendFactorZero; ca.alphaBlendOperation = MTLBlendOperationAdd;
    ca.writeMask = (bits(bm, 3, 1) ? (MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue) : 0) | (bits(bm, 4, 1) ? MTLColorWriteMaskAlpha : 0);
    NSError* error = nil;
    id<MTLRenderPipelineState> state = [device_ newRenderPipelineStateWithDescriptor:d error:&error];
    if (!state) {
      host::log("metal: pipeline build failed: %s", error.localizedDescription.UTF8String);
      return nil;
    }
    pipelines_[key] = state;
    dc.cached_pipeline_owner = backend_id_; dc.cached_pipeline = (__bridge void*)state;
    return state;
  }

  id<MTLFunction> compile(const std::string& source, const char* entry, const char* what, uint64_t hash) {
    NSError* error = nil;
    MTLCompileOptions* options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> lib = [device_ newLibraryWithSource:[NSString stringWithUTF8String:source.c_str()] options:options error:&error];
    if (!lib) {
      host::log("metal: %s %016llX failed: %s", what, (unsigned long long)hash, error.localizedDescription.UTF8String);
      if (shader_failures_++ < 4) {
        std::ofstream dump("metal_shader_fail_" + std::to_string(hash) + ".metal");
        dump << source;
      }
      return nil;
    }
    return [lib newFunctionWithName:[NSString stringWithUTF8String:entry]];
  }
  id<MTLFunction> vertex_function(uint64_t hash, const VSUid& uid) {
    auto it = vs_functions_.find(hash);
    if (it != vs_functions_.end()) return it->second;
    id<MTLFunction> f = compile(msl::vertex(generate_vertex_shader(uid), uid.numTexGens), "vs_main", "vertex shader", hash);
    vs_functions_[hash] = f;
    return f;
  }
  id<MTLFunction> pixel_function(uint64_t hash, const PSUid& uid) {
    auto it = ps_functions_.find(hash);
    if (it != ps_functions_.end()) return it->second;
    bool early = false;
    id<MTLFunction> f = compile(msl::pixel(generate_pixel_shader(uid), uid.numTexGens, &early), "ps_main", "pixel shader", hash);
    ps_functions_[hash] = f;
    return f;
  }

  // ---- textures and samplers
  id<MTLTexture> get_texture(const TextureRef& t) {
    auto ec = efb_copies_.find(t.addr);
    if (ec != efb_copies_.end() && ec->second.texture) { ec->second.last_used = frame_counter_; return ec->second.texture; }
    if (!t.data) return nil;
    const uint32_t meta[] = {t.width, t.height, t.format, t.mip_levels, t.tlut_format};
    const uint64_t key = t.data->hash ^ hash_bytes(meta, sizeof meta);
    auto it = textures_.find(key);
    if (it != textures_.end()) { it->second.last_used = frame_counter_; return it->second.texture; }
    TextureEntry e;
    e.width = t.width; e.height = t.height; e.levels = std::max(1u, t.mip_levels); e.last_used = frame_counter_;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:t.width height:t.height mipmapped:e.levels > 1];
    td.mipmapLevelCount = e.levels;
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    e.texture = [device_ newTextureWithDescriptor:td];
    uint32_t lw = t.width, lh = t.height;
    const uint8_t* level_src = t.data->image.data();
    const size_t available = t.data->image.size();
    size_t consumed = 0;
    for (uint32_t l = 0; l < e.levels && lw && lh; ++l) {
      const uint32_t bytes = texture_level_bytes(lw, lh, t.format);
      if (consumed + bytes > available) break;
      decode_texture(level_src, lw, lh, t.format, t.data->palette.data(), t.tlut_format, decode_scratch_);
      [e.texture replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:l withBytes:decode_scratch_.data() bytesPerRow:lw * 4];
      level_src += bytes; consumed += bytes;
      lw = std::max(1u, lw / 2); lh = std::max(1u, lh / 2);
    }
    id<MTLTexture> tex = e.texture;
    textures_[key] = std::move(e);
    return tex;
  }

  id<MTLSamplerState> get_sampler(uint32_t m0, uint32_t m1) {
    const uint64_t key = (uint64_t)m0 << 32 | m1;
    auto it = samplers_.find(key);
    if (it != samplers_.end()) return it->second;
    static const MTLSamplerAddressMode wrap[] = {MTLSamplerAddressModeClampToEdge, MTLSamplerAddressModeRepeat, MTLSamplerAddressModeMirrorRepeat, MTLSamplerAddressModeRepeat};
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = wrap[bits(m0, 0, 2)]; sd.tAddressMode = wrap[bits(m0, 2, 2)]; sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
    const bool mag_linear = bits(m0, 4, 1);
    const uint32_t minf = bits(m0, 5, 3);
    const bool min_linear = minf & 4;
    const uint32_t mip = minf & 3;
    sd.minFilter = min_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.magFilter = mag_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.mipFilter = mip == 0 ? MTLSamplerMipFilterNotMipmapped : mip == 2 ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
    sd.lodMinClamp = bits(m1, 0, 8) / 16.0f;
    sd.lodMaxClamp = mip ? bits(m1, 8, 8) / 16.0f : 0.0f;
    if (opts_.anisotropy > 1 && min_linear && mag_linear) sd.maxAnisotropy = std::clamp(opts_.anisotropy, 1, 16);
    sd.normalizedCoordinates = YES;
    id<MTLSamplerState> state = [device_ newSamplerStateWithDescriptor:sd];
    samplers_[key] = state;
    return state;
  }

  // ---- commands
  void execute_draw(const Frame& frame, const DrawCall& dc, const DrawMatrices* override_matrices) {
    auto& idx = index_scratch_; idx.clear();
    const uint32_t n = dc.vertex_count;
    MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
    switch (dc.primitive) {
      case 0x80: case 0x88:
        for (uint32_t i = 0; i + 3 < n; i += 4) idx.insert(idx.end(), {i, i + 1, i + 2, i, i + 2, i + 3});
        break;
      case 0x90:
        for (uint32_t i = 0; i + 2 < n; i += 3) idx.insert(idx.end(), {i, i + 1, i + 2});
        break;
      case 0x98:
        for (uint32_t i = 2; i < n; ++i) { if (i & 1) idx.insert(idx.end(), {i - 1, i - 2, i}); else idx.insert(idx.end(), {i - 2, i - 1, i}); }
        break;
      case 0xA0:
        for (uint32_t i = 2; i < n; ++i) idx.insert(idx.end(), {0, i - 1, i});
        break;
      case 0xA8:
        prim = MTLPrimitiveTypeLine;
        for (uint32_t i = 0; i + 1 < n; i += 2) idx.insert(idx.end(), {i, i + 1});
        break;
      case 0xB0:
        prim = MTLPrimitiveTypeLine;
        for (uint32_t i = 1; i < n; ++i) idx.insert(idx.end(), {i - 1, i});
        break;
      default:
        return;   // points are not drawn
    }
    if (idx.empty()) return;
    // Viewport and scissor first: an empty scissor skips the whole draw.
    const float* vp = (const float*)&dc.xf_regs[0x1A];
    const float s = (float)scale_;
    float X = (vp[3] - vp[0] - 342.0f) * s, Y = (vp[4] + vp[1] - 342.0f) * s, W = 2.0f * vp[0] * s, H = -2.0f * vp[1] * s;
    if (W < 0) { X += W; W = -W; }
    if (H < 0) { Y += H; H = -H; }
    float min_depth = 1.0f - vp[5] / 16777216.0f, max_depth = 1.0f - (vp[5] - vp[2]) / 16777216.0f;
    min_depth = std::clamp(min_depth, 0.0f, 1.0f); max_depth = std::clamp(max_depth, 0.0f, 1.0f);
    if (max_depth < min_depth) std::swap(min_depth, max_depth);
    const uint32_t tl = dc.bp.reg[BP_SCISSORTL], br = dc.bp.reg[BP_SCISSORBR], so = dc.bp.reg[BP_SCISSOROFFSET];
    const int xoff = (int)bits(so, 0, 10) * 2 - 342, yoff = (int)bits(so, 10, 10) * 2 - 342;
    int sl = (int)bits(tl, 12, 12) - xoff - 342, st = (int)bits(tl, 0, 12) - yoff - 342;
    int sr = (int)bits(br, 12, 12) - xoff - 341, sb = (int)bits(br, 0, 12) - yoff - 341;
    sl = std::clamp(sl, 0, EFB_WIDTH); sr = std::clamp(sr, 0, EFB_WIDTH); st = std::clamp(st, 0, EFB_HEIGHT); sb = std::clamp(sb, 0, EFB_HEIGHT);
    if (sr <= sl || sb <= st) return;

    uint8_t* vcpu; size_t voffset;
    const size_t vbytes = (size_t)n * sizeof(Vertex);
    if (!vertex_ring_[slot_].alloc(vbytes, 16, &vcpu, &voffset)) { if (!ring_full_logged_) { host::log("metal: vertex ring full"); ring_full_logged_ = true; } return; }
    const Vertex* vsrc = (override_matrices && override_matrices->vertices) ? override_matrices->vertices : &frame.vertices[dc.first_vertex];
    std::memcpy(vcpu, vsrc, vbytes);
    uint8_t* icpu; size_t ioffset;
    if (!index_ring_[slot_].alloc(idx.size() * 4, 4, &icpu, &ioffset)) { if (!ring_full_logged_) { host::log("metal: index ring full"); ring_full_logged_ = true; } return; }
    std::memcpy(icpu, idx.data(), idx.size() * 4);
    uint8_t* ccpu; size_t vs_offset, ps_offset;
    if (!constant_ring_[slot_].alloc(sizeof(VSConstants), 256, &ccpu, &vs_offset)) { if (!ring_full_logged_) { host::log("metal: constant ring full"); ring_full_logged_ = true; } return; }
    VSConstants vs_constants;
    fill_vs_constants(dc, vs_constants, scale_, override_matrices);
    std::memcpy(ccpu, &vs_constants, sizeof vs_constants);
    if (!constant_ring_[slot_].alloc(sizeof(PSConstants), 256, &ccpu, &ps_offset)) return;
    PSConstants ps_constants;
    fill_ps_constants(dc, ps_constants, scale_);
    std::memcpy(ccpu, &ps_constants, sizeof ps_constants);

    id<MTLRenderPipelineState> pipeline = get_pipeline(dc, prim);
    if (!pipeline) return;
    ensure_efb_pass();
    if (pipeline != bound_pipeline_) { [encoder_ setRenderPipelineState:pipeline]; bound_pipeline_ = pipeline; }
    id<MTLDepthStencilState> depth = depth_state(dc.bp.zmode() & 0x1F);
    if (depth != bound_depth_) { [encoder_ setDepthStencilState:depth]; bound_depth_ = depth; }
    static const MTLCullMode cull_modes[] = {MTLCullModeNone, MTLCullModeBack, MTLCullModeFront, MTLCullModeBack};
    const int cull = dc.bp.cullmode() & 3;
    if (cull != bound_cull_) { [encoder_ setCullMode:cull_modes[cull]]; bound_cull_ = cull; }
    [encoder_ setVertexBufferOffset:voffset atIndex:0];
    [encoder_ setVertexBuffer:constant_ring_[slot_].buffer offset:vs_offset atIndex:1];
    [encoder_ setFragmentBuffer:constant_ring_[slot_].buffer offset:ps_offset atIndex:1];
    id<MTLTexture> textures[8]; id<MTLSamplerState> samplers[8];
    for (int i = 0; i < 8; ++i) {
      textures[i] = dc.textures[i].used ? get_texture(dc.textures[i]) : nil;
      samplers[i] = dc.textures[i].used ? get_sampler(dc.textures[i].mode0, dc.textures[i].mode1) : blit_sampler_;
      if (!textures[i]) textures[i] = white_texture();
    }
    [encoder_ setFragmentTextures:textures withRange:NSMakeRange(0, 8)];
    [encoder_ setFragmentSamplerStates:samplers withRange:NSMakeRange(0, 8)];
    MTLViewport viewport{X, Y, std::max(W, 1.0f), std::max(H, 1.0f), min_depth, max_depth};
    [encoder_ setViewport:viewport];
    MTLScissorRect scissor{(NSUInteger)(sl * scale_), (NSUInteger)(st * scale_), (NSUInteger)((sr - sl) * scale_), (NSUInteger)((sb - st) * scale_)};
    [encoder_ setScissorRect:scissor];
    [encoder_ drawIndexedPrimitives:prim indexCount:idx.size() indexType:MTLIndexTypeUInt32 indexBuffer:index_ring_[slot_].buffer indexBufferOffset:ioffset];
    ++draws_this_frame_;
  }

  id<MTLTexture> white_texture() {
    if (white_) return white_;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    white_ = [device_ newTextureWithDescriptor:td];
    const uint8_t px[4] = {255, 255, 255, 255};
    [white_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:px bytesPerRow:4];
    return white_;
  }

  void clear_efb(const EfbCopy& c) {
    ensure_efb_pass();
    ClearConstants cc{};
    cc.color[0] = ((c.clear_color >> 16) & 0xFF) / 255.0f; cc.color[1] = ((c.clear_color >> 8) & 0xFF) / 255.0f;
    cc.color[2] = (c.clear_color & 0xFF) / 255.0f; cc.color[3] = ((c.clear_color >> 24) & 0xFF) / 255.0f;
    cc.depth = 1.0f - (float)c.clear_z / 16777215.0f;
    const uint32_t x0 = std::min<uint32_t>(c.src_x * scale_, efb_w_), y0 = std::min<uint32_t>(c.src_y * scale_, efb_h_);
    const uint32_t x1 = std::min<uint32_t>((c.src_x + c.src_w) * scale_, efb_w_), y1 = std::min<uint32_t>((c.src_y + c.src_h) * scale_, efb_h_);
    if (x1 <= x0 || y1 <= y0) return;
    [encoder_ setRenderPipelineState:clear_pipeline_];
    [encoder_ setDepthStencilState:clear_depth_state_];
    [encoder_ setCullMode:MTLCullModeNone];
    [encoder_ setViewport:MTLViewport{0, 0, (double)efb_w_, (double)efb_h_, 0, 1}];
    [encoder_ setScissorRect:MTLScissorRect{x0, y0, x1 - x0, y1 - y0}];
    [encoder_ setVertexBytes:&cc length:sizeof cc atIndex:0];
    [encoder_ setFragmentBytes:&cc length:sizeof cc atIndex:0];
    [encoder_ drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    bound_pipeline_ = nil; bound_depth_ = nil; bound_cull_ = -1;
  }

  void execute_copy(const EfbCopy& c) {
    end_pass();
    uint32_t w = c.src_w, h = c.src_h;
    if (c.half_scale) { w = std::max(1u, w / 2); h = std::max(1u, h / 2); }
    const uint32_t sw = w * scale_, sh = h * scale_;
    TextureEntry& e = efb_copies_[c.dest_addr];
    if (!e.texture || e.width != sw || e.height != sh) {
      MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:sw height:sh mipmapped:NO];
      td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModePrivate;
      e.texture = [device_ newTextureWithDescriptor:td];
      e.width = sw; e.height = sh; e.levels = 1;
    }
    e.last_used = frame_counter_;
    if (c.half_scale) {
      MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
      rp.colorAttachments[0].texture = e.texture;
      rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
      rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> enc = [command_ renderCommandEncoderWithDescriptor:rp];
      BlitConstants bc{{(float)c.src_w / EFB_WIDTH, (float)c.src_h / EFB_HEIGHT, (float)c.src_x / EFB_WIDTH, (float)c.src_y / EFB_HEIGHT},
                       {0, 0, 0, 0}, {1, 1, 0, 0}};
      [enc setRenderPipelineState:blit_copy_];
      [enc setVertexBytes:&bc length:sizeof bc atIndex:0];
      [enc setFragmentBytes:&bc length:sizeof bc atIndex:0];
      [enc setFragmentTexture:efb_color_ atIndex:0];
      [enc setFragmentSamplerState:blit_sampler_ atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [enc endEncoding];
    } else {
      const uint32_t x = std::min<uint32_t>(c.src_x * scale_, efb_w_), y = std::min<uint32_t>(c.src_y * scale_, efb_h_);
      const uint32_t cw = std::min<uint32_t>(sw, efb_w_ - x), ch = std::min<uint32_t>(sh, efb_h_ - y);
      if (!cw || !ch) return;
      id<MTLBlitCommandEncoder> blit = [command_ blitCommandEncoder];
      [blit copyFromTexture:efb_color_ sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(cw, ch, 1)
                  toTexture:e.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit endEncoding];
    }
  }

  void present_efb(const EfbCopy& c) {
    end_pass();
    id<CAMetalDrawable> drawable = [layer_ nextDrawable];
    if (!drawable) return;
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.15, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [command_ renderCommandEncoderWithDescriptor:rp];
    const float ww = (float)drawable.texture.width, wh = (float)drawable.texture.height;
    const float aspect = output_aspect();
    float vw = ww, vh = ww / aspect;
    if (vh > wh) { vh = wh; vw = wh * aspect; }
    const bool portrait = wh > ww * 1.05f;   // touch devices held upright: game on top, controls below
    [enc setViewport:MTLViewport{(ww - vw) * 0.5, portrait ? 0.0 : (wh - vh) * 0.5, vw, vh, 0, 1}];
    BlitConstants bc{{(float)c.src_w / EFB_WIDTH, (float)c.src_h / EFB_HEIGHT, (float)c.src_x / EFB_WIDTH, (float)c.src_y / EFB_HEIGHT},
                     {1.0f / std::max((float)efb_w_, 1.0f), 1.0f / std::max((float)efb_h_, 1.0f), std::clamp(opts_.sharpness, 0.0f, 1.0f), 0.0f},
                     {1, 1, 0, 0}};
    bc.box[0] = (float)std::clamp((int)std::lround((double)c.src_w * scale_ / std::max(vw, 1.0f)), 1, 4);
    bc.box[1] = (float)std::clamp((int)std::lround((double)c.src_h * scale_ / std::max(vh, 1.0f)), 1, 4);
    [enc setRenderPipelineState:blit_present_];
    [enc setVertexBytes:&bc length:sizeof bc atIndex:0];
    [enc setFragmentBytes:&bc length:sizeof bc atIndex:0];
    [enc setFragmentTexture:efb_color_ atIndex:0];
    [enc setFragmentSamplerState:blit_sampler_ atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    draw_overlay(enc, ww, wh);
    [enc endEncoding];
    drawable_ = drawable;
    last_present_ = c;
  }

  struct OvShape { float rect[4]; float color[4]; float params[4]; uint32_t label; float label_w, label_h, pad; };
  struct OvConstants { float size[2]; float alpha; float pad; float labels[16][4]; };

  // Renders the button labels once with the bold system font into an R8 atlas.
  void create_overlay_atlas() {
    const int W = 2048, H = 128, font_px = 88;
    std::vector<uint8_t> pixels((size_t)W * H, 0);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), W, H, 8, W, gray, kCGImageAlphaNone);
    CGFloat white[] = {1.0, 1.0};
    CGColorRef fg = CGColorCreate(gray, white);
    CGColorSpaceRelease(gray);
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, font_px, nullptr);
    // Work in top-down coordinates: flip the CTM and the text matrix so glyphs stay upright.
    CGContextTranslateCTM(ctx, 0, H);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
    int x = 4;
    for (int i = 1; i < host::kOverlayLabelCount && i < 16; ++i) {
      NSDictionary* attrs = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorAttributeName: (__bridge id)fg};
      NSAttributedString* text = [[NSAttributedString alloc] initWithString:[NSString stringWithUTF8String:host::kOverlayLabels[i]] attributes:attrs];
      CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
      CGRect bounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
      const int w = (int)std::ceil(bounds.size.width) + 4, h = (int)std::ceil(bounds.size.height) + 4;
      if (x + w > W || h > H) { CFRelease(line); break; }
      // Glyph box 2px below the top edge, 2px right of `x` (top-down space, flipped text matrix).
      CGContextSetTextPosition(ctx, x + 2 - bounds.origin.x, 2 + bounds.origin.y + bounds.size.height);
      CTLineDraw(line, ctx);
      CFRelease(line);
      overlay_labels_[i][0] = (float)x; overlay_labels_[i][1] = 0.0f; overlay_labels_[i][2] = (float)w; overlay_labels_[i][3] = (float)h;
      x += w + 4;
    }
    CFRelease(font); CFRelease(fg); CGContextRelease(ctx);
    std::vector<uint8_t>& flipped = pixels;   // already top-down
    if (const char* dump = std::getenv("MELEE_DUMP_ATLAS")) {
      std::ofstream out(dump, std::ios::binary);
      out << "P5\n" << W << " " << H << "\n255\n";
      out.write((const char*)flipped.data(), (std::streamsize)flipped.size());
    }
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    overlay_atlas_ = [device_ newTextureWithDescriptor:td];
    [overlay_atlas_ replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:flipped.data() bytesPerRow:W];
  }
  void draw_overlay(id<MTLRenderCommandEncoder> enc, float ww, float wh) {
    if (!overlay_ || !overlay_(overlay_frame_) || overlay_frame_.shapes.empty()) return;
    static_assert(sizeof(OvShape) == 64, "overlay shape layout must match the shader");
    std::vector<OvShape> shapes;
    shapes.reserve(overlay_frame_.shapes.size());
    for (const host::OverlayShape& s : overlay_frame_.shapes)
      shapes.push_back({{s.x0, s.y0, s.x1, s.y1}, {s.r, s.g, s.b, s.a}, {s.corner, s.ring, s.pressed, 0.0f}, s.label, s.label_w, s.label_h, 0.0f});
    OvConstants oc{{ww, wh}, overlay_frame_.alpha, 0.0f, {}};
    std::memcpy(oc.labels, overlay_labels_, sizeof oc.labels);
    [enc setViewport:MTLViewport{0, 0, ww, wh, 0, 1}];
    [enc setRenderPipelineState:overlay_pipeline_];
    [enc setVertexBytes:shapes.data() length:shapes.size() * sizeof(OvShape) atIndex:0];
    [enc setVertexBytes:&oc length:sizeof oc atIndex:1];
    [enc setFragmentBytes:shapes.data() length:shapes.size() * sizeof(OvShape) atIndex:0];
    [enc setFragmentBytes:&oc length:sizeof oc atIndex:1];
    [enc setFragmentTexture:overlay_atlas_ atIndex:0];
    [enc setFragmentSamplerState:blit_sampler_ atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:shapes.size()];
  }


  void capture(const EfbCopy& c, const std::string& path) {
    // Reads the presented EFB region back through a shared texture (development aid).
    const uint32_t x = std::min<uint32_t>(c.src_x * scale_, efb_w_), y = std::min<uint32_t>(c.src_y * scale_, efb_h_);
    const uint32_t w = std::min<uint32_t>(c.src_w * scale_, efb_w_ - x), h = std::min<uint32_t>(c.src_h * scale_, efb_h_ - y);
    if (!w || !h) return;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> staging = [device_ newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cmd = [queue_ commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit copyFromTexture:efb_color_ sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1)
                toTexture:staging destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    std::vector<uint8_t> pixels((size_t)w * h * 4);
    [staging getBytes:pixels.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    std::ofstream f(path, std::ios::binary);
    f << "P6\n" << w << ' ' << h << "\n255\n";
    for (size_t i = 0; i < (size_t)w * h; ++i) f.write((const char*)&pixels[i * 4], 3);
    host::log("captured %s (%ux%u)", path.c_str(), w, h);
  }

  void submit(const Frame& frame, const DrawMatrices* overrides) {
    @autoreleasepool {
      if (opts_.efb_scale == 0 && pick_scale() != scale_) { wait_idle(); efb_copies_.clear(); create_efb(); }
      dispatch_semaphore_wait(frame_semaphore_, DISPATCH_TIME_FOREVER);
      ++frame_counter_;
      slot_ = (int)(frame_counter_ % FRAME_SLOTS);
      vertex_ring_[slot_].used = index_ring_[slot_].used = constant_ring_[slot_].used = 0;
      ring_full_logged_ = false;
      draws_this_frame_ = 0;
      command_ = [queue_ commandBuffer];
      drawable_ = nil;
      bool presented = false;
      for (const FrameCommand& cmd : frame.commands) {
        if (cmd.kind == FrameCommand::Draw) {
          execute_draw(frame, frame.draws[cmd.index], overrides ? overrides + cmd.index : nullptr);
        } else {
          const EfbCopy& c = frame.copies[cmd.index];
          if (c.to_xfb) { if (!skip_present_) { present_efb(c); presented = true; } }
          else execute_copy(c);
          if (c.clear) clear_efb(c);
        }
      }
      end_pass();
      if (presented && !opts_.capture_path.empty()) {
        const uint64_t n = frames_presented_ + 1;
        const bool wanted = (opts_.capture_frame && n == opts_.capture_frame) || (opts_.capture_every && n % opts_.capture_every == 0);
        if (wanted) pending_capture_ = true;
      }
      if (drawable_) [command_ presentDrawable:drawable_];
      dispatch_semaphore_t semaphore = frame_semaphore_;
      [command_ addCompletedHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(semaphore); }];
      [command_ commit];
      if (pending_capture_) {
        [command_ waitUntilCompleted];
        pending_capture_ = false;
        std::string path = opts_.capture_path;
        if (opts_.capture_every) {
          char suffix[32]; std::snprintf(suffix, sizeof suffix, "_%05llu.ppm", (unsigned long long)(frames_presented_ + 1));
          const bool ppm = path.size() > 4 && path.compare(path.size() - 4, 4, ".ppm") == 0;
          path = path.substr(0, ppm ? path.size() - 4 : path.size()) + suffix;
        }
        capture(last_present_, path);
      }
      command_ = nil; drawable_ = nil;
      if (presented) ++frames_presented_;
      if (frame_counter_ % 600 == 0) evict();
    }
  }

  void evict() {
    // Drop textures unused for ten seconds; the GPU work referencing them is long complete.
    for (auto it = textures_.begin(); it != textures_.end();) {
      if (it->second.last_used + 600 < frame_counter_) it = textures_.erase(it); else ++it;
    }
  }

  CAMetalLayer* layer_;
  MetalOptions opts_;
  int client_w_, client_h_;
  id<MTLDevice> device_ = nil;
  id<MTLCommandQueue> queue_ = nil;
  id<MTLCommandBuffer> command_ = nil;
  id<MTLRenderCommandEncoder> encoder_ = nil;
  id<CAMetalDrawable> drawable_ = nil;
  dispatch_semaphore_t frame_semaphore_ = nullptr;
  Ring vertex_ring_[FRAME_SLOTS], index_ring_[FRAME_SLOTS], constant_ring_[FRAME_SLOTS];
  MTLVertexDescriptor* vertex_descriptor_ = nil;
  id<MTLRenderPipelineState> blit_present_ = nil, blit_copy_ = nil, clear_pipeline_ = nil, overlay_pipeline_ = nil;
  OverlayProvider overlay_;
  host::OverlayFrame overlay_frame_;
  id<MTLTexture> overlay_atlas_ = nil;
  float overlay_labels_[16][4] = {};
  id<MTLDepthStencilState> clear_depth_state_ = nil;
  id<MTLSamplerState> blit_sampler_ = nil;
  id<MTLTexture> efb_color_ = nil, efb_depth_ = nil, white_ = nil;
  bool efb_needs_clear_ = true, skip_present_ = false, ring_full_logged_ = false, pending_capture_ = false;
  int scale_ = 1, efb_w_ = EFB_WIDTH, efb_h_ = EFB_HEIGHT, slot_ = 0;
  uint64_t frame_counter_ = 0, frames_presented_ = 0, backend_id_ = (uint64_t)(uintptr_t)this;
  int shader_failures_ = 0, draws_this_frame_ = 0;
  id<MTLRenderPipelineState> bound_pipeline_ = nil;
  id<MTLDepthStencilState> bound_depth_ = nil;
  int bound_cull_ = -1;
  EfbCopy last_present_{};
  std::unordered_map<PsoKey, id<MTLRenderPipelineState>, PsoKeyHash> pipelines_;
  std::unordered_map<uint64_t, id<MTLFunction>> vs_functions_, ps_functions_;
  std::unordered_map<uint32_t, id<MTLDepthStencilState>> depth_states_;
  std::unordered_map<uint64_t, TextureEntry> textures_;
  std::unordered_map<uint32_t, TextureEntry> efb_copies_;
  std::unordered_map<uint64_t, id<MTLSamplerState>> samplers_;
  std::vector<uint32_t> index_scratch_;
  std::vector<uint8_t> decode_scratch_;
};

}  // namespace

Backend* create_metal_backend(void* layer, int w, int h, const MetalOptions& options) {
  return new MetalBackend((__bridge CAMetalLayer*)layer, w, h, options);
}
void metal_resize(Backend* backend, int w, int h) { static_cast<MetalBackend*>(backend)->resize(w, h); }
void metal_set_options(Backend* backend, const MetalOptions& options) { static_cast<MetalBackend*>(backend)->set_options(options); }
uint64_t metal_frames_presented(Backend* backend) { return static_cast<MetalBackend*>(backend)->frames_presented(); }
void metal_set_overlay(Backend* backend, OverlayProvider provider) { static_cast<MetalBackend*>(backend)->set_overlay(std::move(provider)); }

}  // namespace gx
