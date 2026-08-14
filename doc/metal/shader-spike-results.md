# Shader spike result

Translation feasibility: **accepted on the pinned baseline**. Mandatory family
semantic parity: **not run**.

All 13 recipes pass the complete build-time path: compiler-linked GLSL objects,
SPIR-V validation and reflection, cross-stage interface validation,
SPIRV-Cross, Apple's Metal compiler, per-program `.metallib` linking, and real
`MTLRenderPipelineState` creation under Metal API validation. The set contains
11 runtime contracts, a depth-writing FXAA capability probe, and a separate
16-channel indexed-texture stress case, covering all ten required families. A
second build root reproduced all 91 checked artifacts byte for byte.

| Program | Required family | Recipe | Metal PSO | Metal warnings |
| --- | --- | --- | ---: | ---: |
| `ui_font` | UI and font glyph | runtime | pass | 0 |
| `indexed_material` | Indexed-texture material | runtime, 4 channels | pass | 0 |
| `indexed_material_stress_16` | Indexed-texture material | stress, 16 channels | pass | 0 |
| `deferred_diffuse` | Deferred diffuse | runtime | pass | 0 |
| `pbr_opaque` | PBR opaque and alpha | runtime | pass | 0 |
| `pbr_alpha` | PBR opaque and alpha | runtime | pass | 2 |
| `terrain` | Terrain | runtime | pass | 0 |
| `avatar_skinning` | Avatar skinning | runtime | pass | 1 |
| `shadow_alpha_mask` | Shadow alpha mask | runtime | pass | 0 |
| `reflection_probe` | Reflection probe | runtime | pass | 0 |
| `depth_copy` | Depth write and copy | runtime | pass | 0 |
| `fxaa` | SMAA or FXAA | runtime, depthless | pass | 1 |
| `fxaa_depth_write` | SMAA or FXAA | capability | pass | 1 |

The five warnings are unused generated constant declarations. The gate rejects
possibly-uninitialized diagnostics; none remain. Full output is retained in
the local report. Compilation success does not waive semantic checks or make
the remaining warnings accepted renderer behavior.

## Shared compatibility decisions

- Each Firestorm shader object keeps its own preprocessing environment;
  glslang performs the stage link. Source text is not concatenated or merged.
- glslang's relaxed Vulkan mode collects active loose value uniforms into a
  reflected default uniform block. Textures, images, samplers, and existing
  named blocks remain reflected resources with deterministic bindings.
- A structural SPIR-V pass assigns reserved Firestorm vertex locations and one
  deterministic, cross-stage varying map. It parses decorations and entry-point
  interfaces, and rejects missing, ambiguous, colliding, or unsupported shapes.
- SPIR-V uses one shared optimization profile, including removal of unused
  interface variables, then is validated after structural location assignment.
  Interface type and interpolation semantics are checked across stages.
- Manifest-owned descriptors model Firestorm's source-backed attachment
  formats and `LLVertexBuffer` SoA streams, including normalized byte colors,
  scalar avatar weights, and the indexed-texture value stored in
  `position.w`.
- The shadow coverage includes both the depth-only alpha-mask producer and a
  real sun-shadow consumer. The latter contains 20 SPIR-V comparison-sample
  operations and reflects four Metal depth-texture bindings.
- Metal defines `FXAA_NO_DEPTH_WRITE` for the real depthless post target. The
  source-controlled default depth-writing form remains covered by the separate
  capability recipe; it is not presented as a runtime Metal path.
- Every resulting library is tested by constructing the declared Metal render
  pipeline, not merely by packaging AIR into a metallib. Pipeline reflection
  must exactly match stage bindings, buffer sizes and recursive member layouts,
  and texture access, dimension, scalar type, array length, and depth usage.
- Entry-point names are stable program ID plus stage names.
- The manifest and all 50 source/provenance inputs are captured once; source
  validation, both build roots, and report hashes use those same immutable
  bytes.
- Metal compilation uses stable relative inputs and reproducibility flags; the
  default run compares generated artifacts from two distinct roots.

These are build-wide rules with no shader-ID exception and no regex rewriting
of GLSL, SPIR-V text, or generated MSL. If later recipes require per-shader
rewriting or exceptions, the plan's stop condition applies and MSL should
become canonical.

## Scope and remaining gates

This result proves that the selected translation architecture can build and
link representative Firestorm programs into structurally valid Metal
pipelines. It does not prove rendering equivalence. The mandatory family pass
conditions still need deterministic draws and readback for orientation,
blending, G-buffer channels, terrain, shadows, probe faces and mips, depth
reconstruction, and final gamma. Avatar CPU/runtime layout parity is also still
open; Metal-side reflection alone does not close it.

The pinned OpenGL oracle corpus remains intentionally incomplete until its
fixtures, test identity, capture instrumentation, repeated screenshots,
timings, memory measurements, and self-variance are available. No visual or
performance parity claim is made here.

## Reproduction record

- Source commit: `1e8fd5491bde91fe6daca7d78f217a4d46084a5b`
- Host architecture: arm64
- Host OS: macOS 26.5.2 (25F84)
- Xcode: 26.6 (17F113)
- Metal compiler: 32023.883, installed optional toolchain 17F109
- glslang: 16.3.0
- SPIRV-Cross: 1.4.350.0
- SPIRV-Tools: 2026.2

The checked-in evidence is environment-neutral. Generated GLSL wrappers,
SPIR-V, reflection, MSL, AIR, metallibs, pipeline specifications, compiler
output, hashes, and `report.json` are regenerated under
`.build/metal-shader-spike`.
