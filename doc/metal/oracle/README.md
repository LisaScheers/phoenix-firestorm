# OpenGL oracle corpus

`oracle-corpus.json` is the canonical capture contract for comparing the Metal
renderer with the pinned OpenGL renderer. It is evidence scaffolding, not a
parity claim and not a second shipping backend.

The corpus pins OpenGL to commit
`1e8fd5491bde91fe6daca7d78f217a4d46084a5b`. Every slot records exact settings,
camera, fixture content, time/weather, display scale, and output resolution. A
complete slot also requires three repeated captures, computed self-variance,
CPU/GPU frame timing, process/GPU memory, hardware and OS details, and an
explicit known-quirks list. SHA-256 hashes cover every stored artifact.

The required slots cover login/UI/fonts, opaque and terrain geometry, legacy
and PBR materials, avatars and alpha, HUDs and name tags, impostors, particles,
water/sky/shadows, reflection probes, paired day and night environments,
post-processing, local media, asset previews, tools, snapshots, and raw
readback. Rendered-world slots explicitly pin `RenderHDREnabled=true` and
`RenderEnableEmissiveBuffer=false`, matching the baseline three-attachment
G-buffer contract.

## Readiness gates

Each slot has two independent gates. Its `definition_status` cannot become
`ready` until its fixture is available, its asset manifest and every named asset
exist with matching sizes and SHA-256 hashes, and any fixed environment has a
concrete asset identity. Its `machine_contract_status` cannot become `ready`
until an automated, deterministic driver and capture path can produce the
required artifacts. Recording requires both gates to be ready: a ready
definition is not by itself permission to record captures.

The corpus currently leaves every machine contract blocked. `verify` reports
definition blockers and machine-contract blockers separately, so a fixture
definition can be completed without implying that machine-produced evidence is
admissible.

## Safety boundary

Use only the detached `metal-opengl-oracle` worktree and a disposable local
viewer configuration. Do not log in with a production account, modify a live
region, or publish this build to a daily-driver or production channel. The
helper only stages local requests and records files supplied to it; it does not
start the viewer, log in, upload content, or change any remote state.

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

The session binds both readiness gates into each slot definition, and each
request repeats the current definition and machine-contract statuses and
blockers. A request must not be treated as capture authorization while either
gate is blocked.

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

### Login UI route

The `login_ui` slot uses
`LoginPage=http://127.0.0.1:19472/login_ui/index.html` and an empty
`ForceLoginURL`. That route exists only in PR #25's explicit developer build:
configure the viewer with `-DENABLE_OPENGL_ORACLE_CAPTURE=ON`. The default
build keeps normal login-page behavior, and `ForceLoginURL` must remain empty
to avoid its force-login modal. The checked-in fixture and its manifest make
the login definition ready, but its machine contract remains blocked until a
deterministic driver can prove the loaded page and capture state. Start the
fixture server before the viewer:

```sh
python3 scripts/metal/oracle_login_fixture.py
```

It serves only the validated snapshot on `127.0.0.1:19472`; this repository
does not yet include a deterministic driver or capture hook. In the same
developer build, an optional preflight receipt can be requested with:

```sh
--set OpenGLOracleLoginNavigationReceipt /private/tmp/login-navigation.json
```

The viewer writes that receipt only if its first observed navigation completion
matches the pinned endpoint and returns `200`; an earlier nonmatching
completion produces no receipt. It is explicitly `inadmissible`: it proves
neither the response body or hash nor a painted frame or pixel capture, and
does not change the blocked `login_ui` machine contract.

### Login visual profile

The `login_ui` conditions pin a declarative visual profile. Start from an
isolated seeded OS user-app root, not merely `--settings`. It must contain no
user settings or session overrides, `fsdata_defaults.*`, credentials,
`stored_favorites.xml`, browser profile or plugin cookies, or user overrides
under `skins/default/firestorm`. Launch without a command-line credential,
grid, location, or noninteractive override. Use a non-OpenSim developer build
configured with `-DENABLE_OPENGL_ORACLE_CAPTURE=ON` and keep the fixture server
running before the viewer starts.

The expected result is a blank/new layout: no stored accounts or favorites,
last-location selected, the grid selector hidden, and no modal dialog or
transient notification, including the whitelist reminder. After window
creation, verify that the realized raw drawable and capture are exactly
1920x1080 pixels at backing scale 2.0 in sRGB
`windowed_no_occlusion` mode.

The canonical settings map fixes the English Firestorm skin and theme, font
settings, UI scale, DPI, HiDPI behavior, login location, grid visibility,
credential remembrance, proxy, headless/noninteractive behavior, and the UI
anti-aliasing settings.

This profile is declarative only. Corpus validation confirms the exact
configuration record, not that a running viewer applied it, loaded the page,
or painted a frame. CEF/macOS sans-serif fallback remains an unverified visual
blocker, not something this declaration can establish. It is neither runtime
proof nor capture permission; the navigation receipt remains inadmissible and
the `login_ui` machine contract remains blocked.

On macOS, the non-OpenSim developer capture build can optionally write a
runtime layout preflight receipt:

```sh
--set OpenGLOracleLoginVisualProfileReceipt /private/tmp/login-visual-profile.json
```

The viewer takes one snapshot after two idle passes following `FSPanelLogin`
construction. It writes a receipt only when the live configuration, selected
new login XUI, empty login state, visible controls, applied font metrics, and
observable window geometry all match the pinned preflight conditions. The
receipt is explicitly `inadmissible` and is a preflight only: it is not proof
of the isolated visual profile, CEF response body or hash, selected font
fallback, sRGB or lack of OS occlusion, a painted or presented frame, capture
readiness, pixels, or capture output. It does not change the blocked
`login_ui` machine contract.

For a slot whose definition and machine contract are both ready:

1. Apply every condition from its request before the warmup interval.
2. Leave the camera, settings, environment, display, and content unchanged.
3. Measure 600 frames and capture three 1920x1080 PNGs.
4. Copy the request's `measurement_template` into a new JSON file and replace
   the timing, memory, hardware, and OS `null` values with observed finite data.
   Leave `self_variance` as `null`; the helper computes it from the captures.
   `viewer_build` must be the pinned 40-character baseline commit. Keep
   `known_quirks` empty only if the run was checked and no quirk was found.
5. Record the slot:

```sh
python3 scripts/metal/oracle.py record \
  --slot login_ui \
  --capture /path/to/oracle-01.png \
  --capture /path/to/oracle-02.png \
  --capture /path/to/oracle-03.png \
  --measurements /path/to/login-ui-measurements.json
```

The `tools_readback` slot additionally requires labeled artifacts:

```sh
python3 scripts/metal/oracle.py record \
  --slot tools_readback \
  --capture /path/to/oracle-01.png \
  --capture /path/to/oracle-02.png \
  --capture /path/to/oracle-03.png \
  --measurements /path/to/tools-readback-measurements.json \
  --artifact local_snapshot=/path/to/local-snapshot.png \
  --artifact raw_color=/path/to/frame.bgra \
  --artifact raw_depth=/path/to/frame.depth
```

`media_previews` similarly requires the exact local media payload using
`--artifact local_media_payload=/path/to/payload`; the canonical payload
contract permits 1 byte through 16 MiB.

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

The current `tools_readback` machine contract remains blocked on a capture
hook. That hook must emit the snapshot, raw color, and raw depth together from
one frame; an operator-entered frame ID or hash is not admissible proof. Do not
mark `machine_contract_status` ready or remove that blocker until the
instrumentation and its machine-produced acquisition evidence exist.

Recording reads each artifact once, validates and hashes those exact bytes,
then writes them atomically into the session directory. It refuses
definition-blocked or machine-contract-blocked slots, wrong or incomplete
measurement metadata, a changed oracle checkout, duplicate recording, and
missing supporting artifacts. It also compares the session's baseline, capture
contract, slot definitions, conditions, and canonical definition and condition
hashes with the canonical manifest before trusting mutable evidence. These
comparisons use canonical JSON bytes, so JSON booleans, integers, and
floating-point numbers cannot substitute for one another. Editing a session to
relax a blocker, capture count, feature list, or condition makes both recording
and verification fail.

Verify the complete corpus with:

```sh
python3 scripts/metal/oracle.py verify
```

Verification is expected to fail today. Twelve definitions remain blocked on
unpublished fixtures, fixed environment assets, an offline test identity and
region, or capture instrumentation. All thirteen machine contracts remain
blocked until their deterministic capture paths exist. Those definition and
machine dependencies must be supplied before captures can become admissible.

Run the harness tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest scripts/metal/test_oracle.py
```
