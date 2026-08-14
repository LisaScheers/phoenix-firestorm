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
ctest --test-dir .build/metal-core --output-on-failure
```

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

The CPU contract test is also excluded from an embedded default build. It can
be requested explicitly without registering a test in the viewer's CTest tree:

```sh
cmake --build BUILD_DIR --target firestorm_metal_frame_contracts_test
# Single-config generators:
BUILD_DIR/llwindow/metal/firestorm_metal_frame_contracts_test
# Multi-config generators such as Xcode:
BUILD_DIR/llwindow/metal/CONFIG/firestorm_metal_frame_contracts_test
```
