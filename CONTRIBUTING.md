# Contributing

Changes to source pins, build options, dependency lists, packaging, or license
metadata must be submitted through a pull request.

## Required checks

1. Run `npm run check`.
2. Build the affected target from an empty cache when build definitions change.
3. Verify that LibreMPEG exposes the AC-4 decoder.
4. Verify the libmpv client API and `decoder-list` through the C API.
5. Record any license-impacting configure flag change in `NOTICE.md`.

### Unix notes

- Linux must keep system UI/font libraries shared (PIC-safe `libmpv.so`) and
  bundle `libstdc++` / `libgcc_s` next to the library.
- macOS builds enable Cocoa + Swift (`swift-build`, `gl-cocoa`, `macos-cocoa-cb`).
  Confirm `xcrun -find swiftc` works before filing a macOS packaging PR.
- After packaging, `build/unix/build.sh` smoke-tests `dlopen`. CI also runs
  `scripts/verify-unix-runtime.sh`.

When changing link strategy or meson feature flags, bump `BUILD_PROFILE` in
`build/unix/build.sh` so cached build trees reconfigure instead of reusing a
stale ninja graph.

### Windows notes

- Prefer the GHCR deps image (`npm run windows:deps-image-name`) so CI only
  rebuilds LibreMPEG + libmpv. Changing `builder` or Windows package recipes
  rebuilds `windows-mingw-deps` (slow, rare).
- ccache is required for incremental compiles; keys must not include
  `github.run_id`. Cache path: `.cache/windows-ccache`.
- `BUILD_MODE=full` is the slow fallback when the deps image cannot be pulled.


Release artifacts are immutable. Correct a bad release with a new source pin or
packaging revision instead of replacing an existing asset.

