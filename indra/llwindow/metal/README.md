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

## Firestorm build integration

The same CMake file can be included from `indra/llwindow/CMakeLists.txt`:

```cmake
if (DARWIN)
  add_subdirectory(metal)
endif ()
```

The bootstrap's architecture, deployment target, ARC flag, shader build, and
framework dependencies are target-scoped. They do not change existing
`llwindow` sources or the viewer's renderer selection. When embedded, the
developer app is excluded from the default build and can be built explicitly:

```sh
cmake --build BUILD_DIR --target firestorm_metal_bootstrap
```
