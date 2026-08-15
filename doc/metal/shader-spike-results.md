# Shader spike result

Translation feasibility: **accepted on the pinned baseline**. Mandatory family
semantic parity: **not run**.

All 30 recipes pass the complete build-time path: compiler-linked GLSL objects,
SPIR-V validation and reflection, cross-stage interface validation,
SPIRV-Cross, Apple's Metal compiler, per-program `.metallib` linking, and real
`MTLRenderPipelineState` creation under Metal API validation. The set contains
12 scalar runtime contracts, four selectable FXAA runtime recipes, 12
selectable SMAA runtime recipes, a depth-writing FXAA capability probe, and a
separate 16-channel indexed-texture stress case, covering all ten required
families. The 28 bundled AIR pairs also
link in lexical ID then vertex/fragment order into one path-free
`firestorm-declared-programs.metallib`; every runtime PSO is recreated from
that same library under Metal API validation. A second build root reproduced
all 214 checked artifacts byte for byte: the 210 per-program artifacts plus the
combined metallib and path-free JSON/C++ catalog.

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
| `shadow_alpha_receiver` | Shadow alpha mask | runtime, 4 channels | pass | 2 |
| `reflection_probe` | Reflection probe | runtime | pass | 0 |
| `presentation_copy` | Depth write and copy | runtime | pass | 0 |
| `depth_copy` | Depth write and copy | runtime | pass | 0 |
| `fxaa_low` | SMAA or FXAA | runtime variant, preset 12 | pass | 1 |
| `fxaa_medium` | SMAA or FXAA | runtime variant, preset 23 | pass | 1 |
| `fxaa_high` | SMAA or FXAA | runtime variant, preset 28 | pass | 1 |
| `fxaa` | SMAA or FXAA | runtime, Ultra preset 39, depthless | pass | 1 |
| `smaa_edge_low` | SMAA or FXAA | runtime variant, edge Low | pass | 1 |
| `smaa_edge_medium` | SMAA or FXAA | runtime variant, edge Medium | pass | 1 |
| `smaa_edge_high` | SMAA or FXAA | runtime variant, edge High | pass | 1 |
| `smaa_edge_ultra` | SMAA or FXAA | runtime variant, edge Ultra | pass | 1 |
| `smaa_weights_low` | SMAA or FXAA | runtime variant, weights Low | pass | 1 |
| `smaa_weights_medium` | SMAA or FXAA | runtime variant, weights Medium | pass | 1 |
| `smaa_weights_high` | SMAA or FXAA | runtime variant, weights High | pass | 3 |
| `smaa_weights_ultra` | SMAA or FXAA | runtime variant, weights Ultra | pass | 3 |
| `smaa_neighborhood_low` | SMAA or FXAA | runtime variant, neighborhood Low | pass | 0 |
| `smaa_neighborhood_medium` | SMAA or FXAA | runtime variant, neighborhood Medium | pass | 0 |
| `smaa_neighborhood_high` | SMAA or FXAA | runtime variant, neighborhood High | pass | 0 |
| `smaa_neighborhood_ultra` | SMAA or FXAA | runtime variant, neighborhood Ultra | pass | 0 |
| `fxaa_depth_write` | SMAA or FXAA | capability | pass | 1 |

The 22 Metal warnings are unused generated constant declarations. The gate
rejects possibly-uninitialized diagnostics; none remain. Full output is
retained in the local report. Compilation success does not waive semantic
checks or make the remaining warnings accepted renderer behavior.

## Shared compatibility decisions

- Each stage declares nonempty program-local objects and a possibly empty set
  of feature objects. Program objects receive recipe class/defines; feature
  objects receive baseline class/global defines. Every shader object keeps its
  own preprocessing environment and glslang performs the stage link. A uniform
  420-pack preamble enables canonical line continuations without normalizing or
  rewriting source text.
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
- The shadow family includes the depth-only alpha-mask producer and the real,
  indexed `gDeferredAlphaProgram` receiver. Its `HAS_SUN_SHADOW` entry shader
  links the `SUN_SHADOW` form of `shadowUtil.glsl`; the generated fragment stage
  contains 20 SPIR-V comparison-sample operations, 20 MSL `.sample_compare`
  calls, and four reflected Metal depth-texture bindings. Each shadow-sampling
  recipe owns an exact per-stage count in the manifest, so losing any of the
  current cascade sampling work fails both frontend gates.
- Metal defines `FXAA_NO_DEPTH_WRITE` for the real depthless post target. The
  source-controlled default depth-writing form remains covered by the separate
  capability recipe; it is not presented as a runtime Metal path.
- The bundled FXAA set preserves the source array's exact Low, Medium, High,
  and Ultra ordering: indices 0 through 3 select presets 12, 23, 28, and 39.
  Artifact schema v2 carries `gFXAAProgram`, the optional source index, shader
  class 3, and typed `RenderFSAAType=1`/`RenderFSAASamples=index` overrides.
  Scalar program globals retain a null source index, and duplicate selector
  triples fail catalog generation and ordinary-C++ validation.
- The bundled SMAA set preserves all three source arrays and the exact Low,
  Medium, High, and Ultra ordering. Edge detection, blend weights, and
  neighborhood blending each use indices 0 through 3, shader class 3,
  `RenderFSAAType=2`, and `RenderFSAASamples=index`. Both the pass shader and
  `deferred/SMAA.glsl` are program-local objects that receive the common and
  quality defines; shared deferred features retain their global environment.
- The `presentation_copy` runtime recipe uses the real `gCopyProgram` sources
  with one BGRA8Unorm color target, the position-only vertex contract, and the
  paired `diffuseMap` texture and sampler. Both stages expose no uniform
  buffers, so the first artifact-driven presentation draw does not depend on a
  recursive CPU uniform packer. Its semantic parity remains `not_run`.
- Every resulting library is tested by constructing the declared Metal render
  pipeline, not merely by packaging AIR into a metallib. Pipeline reflection
  must exactly match stage bindings, buffer sizes and recursive member layouts,
  and texture access, dimension, scalar type, array length, and depth usage.
  Artifact schema v2 admits only the matrix layouts present here: `mat3` and
  `mat4`, column-major with stride 16. Producer, catalog, and native schema
  validation reject other shapes, strides, or major orders, while native
  reflection proves the remaining matrix data type.
- Entry-point names are stable program ID plus stage names.
- The runtime-only artifact has exactly the combined library's 56 expected
  entry points. Its immutable C++17 descriptors use the existing renderer
  `PixelFormat`, typed vertex layouts and stage buffer/texture/sampler
  summaries, per-buffer layout digests, and full per-stage reflection digests.
  The path-free JSON and canonical digests preserve recursive member layouts,
  including the canonical v1 matrix stride and major order; C++ does not
  duplicate that member tree. Logical binding names remain semantic authority,
  while generated `metal_name` values are checked exactly against native
  reflection and remain toolchain-owned diagnostic identity rather than a
  persistence ABI. The catalog identifies its frozen source manifest and
  explicit resource basename without embedding a host, build, or source path.
- The manifest and all 60 source/provenance inputs are captured once; source
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
link 28 representative Firestorm runtime recipes and variants into
structurally valid Metal pipelines. It also proves exact typed catalog lookup
for the four source-backed FXAA quality indices and all 12 source-backed SMAA
pass/quality selections. It is not the complete viewer
shader inventory and does not prove renderer selection integration or
rendering equivalence. The mandatory family pass
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
