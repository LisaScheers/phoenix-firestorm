# Firestorm Metal presentation bootstrap

This target is the first native Metal presentation slice. It creates a
`CAMetalLayer`, loads an offline-compiled `.metallib`, clears to black, and
presents one colored triangle.

The view redraws only when AppKit invalidates it, its size or backing scale
changes, an occluded window becomes visible, or the C++ caller explicitly asks
for a frame. There is no display link or continuous repaint loop.

## Standalone build

The optional Xcode Metal Toolchain component must be installed.

```sh
cmake -S indra/llwindow/metal -B .build/metal-bootstrap -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build .build/metal-bootstrap
.build/metal-bootstrap/firestorm-metal-bootstrap.app/Contents/MacOS/firestorm-metal-bootstrap \
  --self-test
```

The target is fixed to arm64 and macOS 13 or newer. `--self-test` opens a
short-lived accessory window, submits a frame, waits at most five seconds for
both GPU completion and drawable presentation, reports the result, and exits.
Running without `--self-test` opens the event-driven developer window.

For focused transient-drawable verification, use
`--self-test-drawable-retry`. It injects one drawable-acquisition miss, checks
that no frame was submitted, and verifies that exactly one queued retry is
completed and presented.

The standalone build also includes an ordinary C++17 test for the three-slot
frame lifecycle and non-wrapping transient allocator:

```sh
(cd .build/metal-bootstrap && ctest --output-on-failure)
```

`FrameSlots` accepts at most three concurrent frames and rejects stale or
wrong-state generation tokens. Calls are synchronized for the intended model
of one recording/submission thread plus completion callbacks from any thread.
`TransientArena` is thread-confined, supports any positive alignment, and
retains its high-water mark across resets.

## Deterministic offscreen validation

The standalone build also provides a headless resource test. It renders exact
corner colors into a private 2×2 texture, blits them into a shared buffer, and
validates the top-to-bottom rows only after command-buffer completion. Metal
API and GPU validation are enabled by the registered test.

```sh
cmake -S indra/llwindow/metal -B .build/metal-core -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build .build/metal-core --target firestorm_metal_offscreen_test
(cd .build/metal-core && \
  ctest -R '^firestorm_metal_offscreen_orientation$' --output-on-failure)
```

## Resource core contracts

The resource core keeps Metal objects behind an Objective-C-free C++17
boundary. Its checked layout helper covers the formats exercised by the
current shader and attachment work, accepts the transfer path's row alignment,
and rejects invalid extents or arithmetic overflow without assigning row
orientation.

`MetalFrameContext` owns exactly three `MTLStorageModeShared` transient
buffers. Generation-tagged leases prevent reuse while the GPU can still read a
slot. Resources retired against a lease remain alive until that exact command
buffer completes, and successful completion publishes a process-wide monotonic
submission serial only after cleanup makes the slot available again. The
runtime path does not wait for GPU completion; bounded waits exist only in the
focused test.

`MetalPrivateTexture` strongly owns exactly one private 2D, cube, or cube-array
resource behind the Objective-C-free boundary. Cube faces use physical slice
order `+X, -X, +Y, -Y, +Z, -Z`; cube-array slice identity is
`cubeIndex * 6 + face`. Empty resources are supported, while immutable uploads
must supply every `(mip, slice)` exactly once. The transfer path validates the
complete descriptor, identities, source rows, and bounds before allocation,
then repacks all rows without flipping into one 256-byte-aligned staging range.
The deliberately portable descriptor subset limits texture edges to 16,384 and
cube arrays to 341 cubes (2,046 physical slices).
Mip generation, partial updates, texture views, 1D/3D/MSAA resources, sparse or
heap allocation, compressed formats, additional sRGB formats, and GL conversion
stay deferred.

`MetalTransferBatch` records bounded uploads into immutable private buffers and
textures using only the current frame lease's shared arena. Asynchronous
readbacks accept any in-bounds physical slice and mip and return explicit row
and image pitches under a separate byte budget. The caller owns the command
buffer and queue; the batch never commits or waits, and resources or bytes are
published only by the frame context's successful completion action.

`PixelFormat::rgba8_unorm_srgb` is a four-byte color format backed by
`MTLPixelFormatRGBA8Unorm_sRGB`. Transfers preserve its stored bytes exactly;
gamma conversion occurs only through normal Metal render-target writes and
texture sampling.

`MetalSamplerCache` validates typed address, minification, magnification, mip,
and anisotropy fields before creating immutable native states. Its explicit
canonical key maps every mip filter to `not_mipmapped` for one-level textures,
so observably equivalent requests share one strongly owned cache entry. Handles
borrowed from the cache remain valid for the cache lifetime.

`MetalDepthStateCache` similarly validates typed compare and write fields and
strongly owns each immutable native depth state by its canonical key. Cull mode
and front-face winding remain explicit typed dynamic encoder state; no
desired-state tracker or pipeline cache is introduced by this slice.

`MetalRenderPipelineFamilyCache` fixes one generated-vertex shader pair, one
color format, optional depth format, and one sample. Only a canonical single
blend attachment varies between its strongly owned pipeline entries. Disabled,
masked, format-absent, and otherwise ignored blend fields share entries without
introducing a global pipeline cache, desired-state tracker, or render-pass
abstraction.

`MetalRenderTarget` strongly groups one private, render-target-capable,
single-sample color texture and an optional matching private Depth32Float
texture. This slice attaches only mip zero of one-slice 2D textures and rejects
textures with additional mips. `MetalRenderPass` maps typed load, store, and
clear actions into a movable RAII encoder scope. It validates the complete
target, descriptor, label, and command-buffer relationship before creating the
native encoder. Finite HDR color clears are accepted; a selected depth clear
must be finite and in `[0, 1]`; unselected clear payloads are ignored.

The pass borrows the command buffer and never commits, waits, submits, or owns a
frame. Callers externally serialize pass creation/use/end with enqueue and
commit on that command buffer. A not-enqueued or explicitly enqueued buffer is
accepted while encoding is still open; a committed buffer is rejected. `end()`
and destruction close an active encoder exactly once. Move assignment
intentionally closes an active destination encoder before taking the source
scope. Encoder handles are borrowed and remain valid only while their pass is
active; attachment handles returned by the target are additional strong owners.

```sh
cmake --build .build/metal-core --target \
  firestorm_metal_resource_layout_test \
  firestorm_metal_frame_context_test \
  firestorm_metal_resource_transfer_test \
  firestorm_metal_texture_subresources_test \
  firestorm_metal_sampler_test \
  firestorm_metal_depth_raster_test \
  firestorm_metal_blend_pipeline_test \
  firestorm_metal_render_pass_test \
  firestorm_metal_color_gamma_test
(cd .build/metal-core && \
  ctest -R '^firestorm_metal_(resource_layout|frame_context|resource_transfer|texture_subresources|sampler|depth_raster|blend_pipeline|render_pass|color_gamma)$' \
    --output-on-failure)
```

The sampler test uploads a private 2x1 RGBA8 texture, samples one out-of-range
coordinate with repeat and clamp states, and reads back exact distinct pixels
through the asynchronous frame-context transfer path. The registered test runs
with Metal API and GPU validation enabled.

The texture-subresource test uploads all two mips of a private RGBA8 cube array
with two cubes. It blits the four mip-zero corners and mip-one center from all
12 physical slices into an exact 12x5 atlas, then checks that atlas plus direct
slice-11/mip-zero and slice-2/mip-one readbacks byte for byte. It also covers
duplicate and missing identities, invalid faces/slices/mips, aggregate staging
limits, success-only publication, out-of-order completion, and strong wrapper
lifetime.

The depth/raster test renders one private 4x1 RGBA8 target with a private
Depth32Float attachment and reads it back asynchronously. Its four exact cells
are green for `Less` with writes enabled, red for `Less` with writes disabled,
blue for clockwise-front back-face culling, and yellow for
counterclockwise-front back-face culling. Each cell uses a 1x1 scissor and two
fullscreen triangles in one command buffer.

The blend/pipeline test seeds and blends nine private RGBA8 cells with separate
RGB and alpha equations, factors, operations, and write masks. It reads back the
exact 9x1 byte row through the asynchronous frame-context transfer path. The
registered test runs with Metal API and GPU validation enabled.

The render-pass test first clears a private 2x1 RGBA8 target to red and a
matching Depth32Float target to `0.5`, storing both. A second pass loads both,
uses `Less` with depth writes disabled, and draws green at depth `0.25` then
`0.75` into separate one-pixel scissors. Its asynchronous 256-byte-pitch
readback must publish only on successful completion and begin with exact
green-then-red RGBA bytes.

The color/gamma test renders a linear RGBA8 constant, samples it into an sRGB
attachment for automatic encoding, samples that attachment back into linear
RGBA8 for automatic decoding, then performs the planned final-display sRGB
conversion in a shader and writes BGRA8. All four private 1x1 resources are
read back asynchronously through one transfer batch; callbacks must retain
registration order and share one submission serial.

The planned presentation policy is one manual final shader encode into a
`BGRA8Unorm` drawable, paired later with an sRGB layer colorspace. The current
`CAMetalLayer` is deliberately unchanged by this resource-contract slice.

## Firestorm build integration

The same CMake file can be included from `indra/llwindow/CMakeLists.txt` by
configuring the viewer with `-DFIRESTORM_BUILD_METAL_BOOTSTRAP=ON`. The option
defaults to off so ordinary viewer configuration does not require the optional
Metal shader toolchain.

The bootstrap's architecture, deployment target, ARC flag, shader build, and
framework dependencies are target-scoped. They do not change existing
`llwindow` sources or the viewer's renderer selection. When embedded, the
developer app is excluded from the default build and can be built explicitly:

```sh
cmake --build BUILD_DIR --target firestorm_metal_bootstrap
```

The contract tests are also excluded from an embedded default build. They can
be requested explicitly without registering tests in the viewer's CTest tree:

```sh
# Single-config generators:
cmake --build BUILD_DIR --target \
  firestorm_metal_frame_contracts_test \
  firestorm_metal_resource_layout_test \
  firestorm_metal_frame_context_test \
  firestorm_metal_resource_transfer_test \
  firestorm_metal_texture_subresources_test \
  firestorm_metal_sampler_test \
  firestorm_metal_depth_raster_test \
  firestorm_metal_blend_pipeline_test \
  firestorm_metal_render_pass_test \
  firestorm_metal_color_gamma_test
# Single-config executables:
BUILD_DIR/llwindow/metal/firestorm_metal_frame_contracts_test
BUILD_DIR/llwindow/metal/firestorm_metal_resource_layout_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_frame_context_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_resource_transfer_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_texture_subresources_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_sampler_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_depth_raster_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_blend_pipeline_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_render_pass_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/firestorm_metal_color_gamma_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
# Multi-config generators such as Xcode:
cmake --build BUILD_DIR --config CONFIG --target \
  firestorm_metal_frame_contracts_test \
  firestorm_metal_resource_layout_test \
  firestorm_metal_frame_context_test \
  firestorm_metal_resource_transfer_test \
  firestorm_metal_texture_subresources_test \
  firestorm_metal_sampler_test \
  firestorm_metal_depth_raster_test \
  firestorm_metal_blend_pipeline_test \
  firestorm_metal_render_pass_test \
  firestorm_metal_color_gamma_test
BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_frame_contracts_test
BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_resource_layout_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_frame_context_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_resource_transfer_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_texture_subresources_test
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_sampler_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_depth_raster_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_blend_pipeline_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_render_pass_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_color_gamma_test \
    --metallib BUILD_DIR/llwindow/metal/generated/bootstrap.metallib
```
