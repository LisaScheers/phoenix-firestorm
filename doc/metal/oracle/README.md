# OpenGL oracle corpus

`oracle-corpus.json` is the canonical capture contract for comparing the Metal
renderer with the pinned OpenGL renderer. It is evidence scaffolding, not a
parity claim and not a second shipping backend.

The corpus pins OpenGL to commit
`1e8fd5491bde91fe6daca7d78f217a4d46084a5b`. Every slot records exact settings,
camera, fixture content, time/weather, display scale, and output resolution. A
complete slot also requires three repeated captures, computed self-variance,
paired per-frame CPU/GPU timing, process resident memory, renderer-accounted
GPU memory, hardware and OS details, and a separately reviewed known-quirks
list. SHA-256 hashes cover every stored artifact.

The required slots cover login/UI/fonts, opaque and terrain geometry, legacy
and PBR materials, avatars and alpha, HUDs and name tags, impostors, particles,
water/sky/shadows, reflection probes, paired day and night environments,
post-processing, local media, asset previews, tools, snapshots, and raw
readback. A slot cannot become `ready` until its fixture is available, its asset
manifest and every named asset exist with matching sizes and SHA-256 hashes,
and any fixed environment has a concrete asset identity. Rendered-world slots
explicitly pin `RenderHDREnabled=true` and
`RenderEnableEmissiveBuffer=false`, matching the baseline three-attachment
G-buffer contract.

## Safety boundary

Use only the detached `metal-opengl-oracle` worktree and a disposable local
viewer configuration. Do not log in with a production account, modify a live
region, or publish this build to a daily-driver or production channel. The
helper only stages local requests and validates machine-produced acquisitions;
it does not start the viewer, log in, upload content, or change remote state.

The `login_ui` runner must launch the viewer with
`--loginpage http://127.0.0.1:19472/login_ui/index.html`, which maps to the
runtime `LoginPage` setting. `ForceLoginURL` must remain empty: that testing
override always opens `WarnForceLoginURL`, contradicting the fixture's required
absence of modal and transient UI.

## Capture workflow

From `metal-backend-foundation`, initialize a local session:

```sh
python3 scripts/metal/oracle.py init \
  --oracle-worktree ../metal-opengl-oracle
```

This writes `.build/metal-oracle/session.json` and one capture request per slot
under `.build/metal-oracle/requests/`. Initialization refuses to overwrite an
existing session or pre-existing/aliased `requests` directory. The resolved
request directory must be the real `requests` child of the canonical session
directory before each request is written. Initialization also verifies that the
oracle worktree is detached at the pinned commit and truly clean. It rejects
untracked files, index
`skip-worktree` or `assume-unchanged` flags, and Git-normalized tracked content
that differs from `HEAD` even when an index flag would normally conceal it.
Repository-selection environment variables, replacement objects,
content-conversion attributes,
ignored untracked files, and mutable file-mode or symlink settings cannot relax
this check.

Ready content uses `asset_manifest_path`, relative to `--fixture-root` (the
repository root by default), plus the manifest's exact byte count and SHA-256.
The fixture manifest must name at least one real asset, and no path may be
absolute, escape the fixture root, or traverse a symbolic link:

```json
{
  "schema": 1,
  "fixture_id": "the-slot-fixture-id",
  "fixture_revision": "the-slot-fixture-revision",
  "assets": [
    {"path": "asset.bin", "bytes": 123, "sha256": "64 lowercase hex digits"}
  ]
}
```

Every request carries immutable `session_id`, kind, corpus hash, baseline,
definition, conditions, their canonical hashes, and the complete capture
contract. It also carries two independent admission decisions:
`definition_status` describes whether the fixture definition is complete, and
`machine_contract_status` describes whether a typed runtime-state driver can
prove that definition. The capture controller and recorder must both reject a
request unless both statuses are `ready`, both blocker lists are empty, and a
supported typed machine contract exists. A ready typed contract pins the
reviewed instrumentation commit and exact viewer executable SHA-256; repeating
self-reported hashes in a receipt is not sufficient. A controller self-test can
exercise settings, display checks, timing, and readback, but is never
admissible corpus evidence.

The corpus-side `typed_runtime_state_v1` contract is deliberately incompatible
with the current hook's `capture_self_test_v1` contract. Its `expected` object
has the exact keys `runtime_settings`, `camera`, `environment`, `display`, and
`fixture_state`. The first four must canonically equal their request conditions.
`fixture_state` has the closed shape below and its `state` object must be
non-empty:

```json
{
  "schema": 1,
  "driver": "a_versioned_fixture_driver_v1",
  "fixture_id": "the-fixture-id",
  "fixture_revision": "the-fixture-revision",
  "asset_manifest_sha256": "64 lowercase hex digits",
  "state": {"driver-defined-semantic-field": "expected value"}
}
```

The fixture identity, revision, and asset-manifest hash must exactly bind the
request. Only a reviewed fixture driver may define and observe the semantic
`state`; the capture controller's generation counter is not a substitute.
The self-test also reports only
`window_mode: "windowed_visible_not_minimized"`; it must never claim the corpus
condition `windowed_no_occlusion`.

All thirteen current requests are intentionally blocked. Fixture payloads and
typed runtime-state drivers do not exist yet, so the developer capture hook
must stop before warmup. Do not edit a generated request or session to bypass
this gate.

Once a slot has a real typed machine contract, the instrumented viewer reads
the request itself, hashes the exact request bytes, and atomically emits one
acquisition directory. Its receipt uses the closed
`firestorm-opengl-oracle-acquisition` schema and contains:

- immutable session, slot, corpus, request, definition, condition, and baseline
  bindings;
- the capture protocol, clean instrumentation commit, executable SHA-256, and
  process-run identity;
- observed typed state and one controller-owned `capture_state_generation`;
- exactly 300 contiguous presented warmup frame serials;
- exactly 600 contiguous presented measurement rows, each pairing CPU time,
  GPU time, RSS, and renderer-accounted GPU bytes under one frame serial;
- three immediately following presented capture frames, excluding their
  synchronous readback stalls from the measurement window;
- safe relative paths, exact byte counts, hashes, frame serials, and transaction
  identities for each capture and supporting artifact; and
- hardware, OS, display, build, and OpenGL identity reported by runtime APIs.

The CPU timing scope is `display_to_pre_swap_wall_v1`: monotonic wall time from
the beginning of the accepted display frame through the pre-swap capture seam.
GPU timing is `gl_time_elapsed_frame_v1` over the paired rendered frame. The
contract deliberately calls GPU memory `renderer_accounted_v1`; it is the sum
of the viewer's texture, vertex-buffer, and render-target attachment accounting
and is not an authoritative OpenGL-driver allocation total. Those sources are
stored as provenance beside every derived memory aggregate.

Known quirks are not machine telemetry. After inspecting the acquisition, an
operator writes a closed `firestorm-opengl-oracle-known-quirks-review` document
containing the session and slot identities, SHA-256 of the exact receipt,
review timestamp, and reviewed list. An empty list means the acquisition was
reviewed and no quirk was found; it is not a default assertion from the hook.

Record the receipt and its separately bound review:

```sh
python3 scripts/metal/oracle.py record \
  --slot login_ui \
  --acquisition /path/to/acquisition/receipt.json \
  --quirks /path/to/acquisition/known-quirks-review.json
```

There is no CLI path for operator-authored timing or memory aggregates. The
recorder strict-parses the request, receipt, and review, rejecting duplicate
keys, non-standard numbers, booleans substituted for numbers, missing or extra
fields, path escapes, and symbolic links. It reads each acquisition artifact
once, validates and hashes those exact bytes, then derives percentiles, memory
start/peak values, and capture self-variance in Python. The pinned percentile
algorithm is sorted linear interpolation over the 600 samples.

Capture PNGs must be non-interlaced 8-bit RGB or RGBA. The capture contract
interprets wholly untagged baseline `LLPngWrapper` output as sRGB; a canonical
`sRGB` chunk or matching `gAMA` plus `cHRM` pair is also accepted. Partial,
conflicting, ICC, cICP, transparency, and APNG declarations are rejected. The
helper validates checksums, color and IDAT ordering, bounded zlib decoding, row
filters, complete scanlines, and exact dimensions. It computes variance over
every unordered capture pair after applying the standard sRGB transfer
function to RGB; alpha remains linear. Metrics use normalized linear `[0,1]`
units under the versioned `linear_srgb_rgba8_all_pairs_v1` method.

`tools_readback` uses canonical typed artifacts at 1920x1080. The local
snapshot is a non-interlaced RGB8 or RGBA8 sRGB-encoded PNG. Raw color is
tightly packed, top-left-origin `bgra8_unorm_srgb_encoded` with a 7680-byte row
pitch and 8,294,400 bytes. The helper compares the exact snapshot pixels with
the exact raw color bytes after the BGRA-to-RGB channel swizzle; alpha must also
match when the snapshot is RGBA. Raw depth is tightly packed, top-left-origin
`depth32_float_le_zero_to_one` with the same row pitch and byte count. Non-finite
depth values are rejected, and the complete role contract is stored beside
each artifact hash.

For `tools_readback`, the hook must emit snapshot, raw color, and raw depth from
one capture frame and one transaction. The recorder validates that binding and
pixel consistency, and requires the local snapshot bytes to equal the PNG for
that capture transaction. A JSON frame ID or hash typed by an operator is not
proof; the value is trusted only as output of the reviewed, pinned hook. The
`media_previews` receipt similarly carries the exact local payload under its
required role contract, which permits 1 byte through 16 MiB.

Recording persists the exact receipt, review, and validated artifact bytes in
one acquisition directory. It refuses a blocked slot, a changed request or
oracle checkout, duplicate recording, unstable generation, gaps or overlaps in
frame serials, unpaired sample telemetry, post-measurement captures that are
not the next three presentations, and incomplete supporting roles. Editing a
session to relax a blocker, capture count, feature list, condition, or machine
contract makes recording and verification fail.

Verify the complete corpus with:

```sh
python3 scripts/metal/oracle.py verify
```

Verification is expected to fail today. All thirteen definitions are explicitly
blocked on a static login page, unpublished fixtures, fixed environment assets,
or an offline test identity and region. Every machine contract is separately
blocked because no typed fixture-state driver exists. Those dependencies must
be supplied and their manifest entries made concrete before captures can
become admissible.

Run the harness tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest scripts/metal/test_oracle.py
```
