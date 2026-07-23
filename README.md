# MpvLibre Runtime

[简体中文](README.zh-CN.md)

Reproducible, redistributable **libmpv** runtimes built on **LibreMPEG** instead
of FFmpeg. Releases target desktop apps that need the mpv client API plus
LibreMPEG codecs such as AC-4.

This project ships a **library runtime only**. It does not include or launch
`mpv.exe` / `mpv`, and it is not tied to Electron or any specific app.

## Platforms

All of the following targets are **CI-verified** (build + AC-4 decode + libmpv
client API). Each release publishes every target in one immutable tag.

| Target | Artifact | Build |
| --- | --- | --- |
| `win32-x64` | `mpv-libre-runtime-win32-x64.7z` | Alpine container, LLVM/MinGW cross-build |
| `darwin-arm64` | `mpv-libre-runtime-darwin-arm64.tar.xz` | Native macOS (Cocoa + Swift + MoltenVK) |
| `darwin-x64` | `mpv-libre-runtime-darwin-x64.tar.xz` | Native macOS (Cocoa + Swift + MoltenVK) |
| `linux-x64` | `mpv-libre-runtime-linux-x64.tar.xz` | Ubuntu (portable shared deps) |
| `linux-arm64` | `mpv-libre-runtime-linux-arm64.tar.xz` | Ubuntu ARM (portable shared deps) |

Binaries are **not** portable across OS or CPU. Load the archive that matches the
host. Status and artifact names are also recorded in
[`versions.lock.json`](versions.lock.json) and each release’s
`runtime-manifest-v1.json`.

## What’s in the archive

**Windows (`win32-x64`)**

```text
libmpv-2.dll
ffmpeg.exe
ffprobe.exe
runtime.json
NOTICE.md
licenses/
```

**Unix (`linux-*`, `darwin-*`)**

```text
lib/libmpv.so.2          # macOS: lib/libmpv.2.dylib
lib/…                    # portable shared libraries (Linux includes libstdc++)
ffmpeg
ffprobe
runtime.json
NOTICE.md
licenses/
```

`ffmpeg` / `ffprobe` come from the same LibreMPEG build (inspection, transcoding,
and tests). Headers and import libraries are omitted; an SDK package may be
published separately later.

## Download and verify

Each release includes platform archives, `.sha256` sidecars,
`runtime-manifest-v1.json`, a corresponding source bundle, and license notes.

```powershell
$release = "RELEASE_TAG"
$base = "https://github.com/Zencok/mpv-libre-runtime/releases/download/$release"
curl.exe -fLO "$base/mpv-libre-runtime-win32-x64.7z"
curl.exe -fLO "$base/mpv-libre-runtime-win32-x64.7z.sha256"
Get-FileHash mpv-libre-runtime-win32-x64.7z -Algorithm SHA256
```

```bash
# Example: Linux x64
release=RELEASE_TAG
base="https://github.com/Zencok/mpv-libre-runtime/releases/download/$release"
curl -fLO "$base/mpv-libre-runtime-linux-x64.tar.xz"
curl -fLO "$base/mpv-libre-runtime-linux-x64.tar.xz.sha256"
sha256sum -c mpv-libre-runtime-linux-x64.tar.xz.sha256
```

Pin an **immutable** release URL and SHA-256. Do not download a floating
`latest` asset from application CI.

## Use libmpv

Load the platform library and call the upstream libmpv C API:

```c
#include <mpv/client.h>

mpv_handle *player = mpv_create();
mpv_set_option_string(player, "config", "no");
mpv_set_option_string(player, "video", "no");

if (mpv_initialize(player) < 0) {
    return 1;
}

const char *command[] = { "loadfile", "MEDIA_PATH", "replace", NULL };
mpv_command(player, command);
mpv_set_property_string(player, "pause", "no");

/* Drive mpv_wait_event() from the host application. */
mpv_terminate_destroy(player);
```

The same ABI works from Rust, C#, Python, Node.js FFI, or a native helper. The
host owns lifecycle, events, threads, rendering, and media-source policy.

On Linux, keep `lib/` on `LD_LIBRARY_PATH` (or next to the process with RPATH).
On macOS, libraries use `@loader_path` under `lib/`.

## Build locally

Requirements common to all targets: **Node.js 22+**, **Git**.

### Windows x64

Docker (Linux containers):

```bash
npm run check
npm run build:windows-x64
# release build + source bundle:
npm run build:windows-x64:release
# force cold full rebuild (no GHCR deps image):
npm run build:windows-x64:full
# build/push the MinGW deps image used by CI (Plan B):
npm run build:windows-x64:deps-image
npm run windows:deps-image-name
```

CI uses two layers:

1. **Deps image (GHCR)** — single self-contained multi-stage `Dockerfile.deps`
   (tools + deps in one Buildx graph; no host `docker load` base). `DEPENDS`
   parsed from package CMake. Built via `windows-runtime` → `windows-mingw-deps`
   with GHA layer cache. Payload slimmed (no `.git`/download tarballs; keep
   install prefixes).
2. **Runtime job** — pulls image, **reconfigures** with real pins, rebuilds only
   LibreMPEG + libmpv, ccache with stable key. Cache save failures do not fail
   the job. Archive checks use deps image or host `7z`.

Local builds pull the deps image when available and fall back to a full in-tree
build otherwise. Pins come from `versions.lock.json`. The output is still a
Windows PE/DLL runtime.

### Unix (macOS / Linux)

Extra tools: Meson, Ninja, NASM, pkg-config.

- **Linux:** build-essential, libass/fontconfig/freetype/harfbuzz/alsa/pulse dev
  packages, patchelf
- **macOS:** Xcode (`swiftc`), Homebrew (`libass`, `meson`, MoltenVK, …)

```bash
npm run check
npm run build:unix -- linux-x64
# npm run build:unix -- linux-arm64
# npm run build:unix -- darwin-arm64
# npm run build:unix -- darwin-x64
```

Packaging notes:

- **Linux:** LibreMPEG/libplacebo are static+PIC; system UI/font libs stay shared
  and are copied beside `libmpv` with `$ORIGIN` RPATH; `libstdc++` is always
  bundled for libplacebo C++ symbols under `dlopen`.
- **macOS:** Cocoa, Swift, `gl-cocoa`, `macos-cocoa-cb`, and Vulkan/MoltenVK for a
  full libmpv surface; non-system dylibs are rewritten to `@loader_path`.

CI verification (all platforms): AC-4 present in `ffmpeg -decoders`, real AC-4
decode of the fixture, libmpv `decoder-list` contains AC-4, archive layout and
licenses.

## Release process

1. A scheduled workflow proposes upstream pin updates via PR (`versions.lock.json`).
2. CI builds and verifies every target.
3. On `main`, releases are **staged on one immutable tag**:
   - **Unix first** — when linux/darwin jobs pass, the tag is created with Unix
     archives and a partial `runtime-manifest-v1.json` (`phase: unix`).
   - **Windows later** — when win32 finishes (independent of Unix success),
     assets and the source bundle are uploaded to the **same tag**. The manifest
     becomes `phase: complete` when all five targets are present, otherwise
     `auto` for whatever is available.
4. Consumers that only need Unix can pin as soon as the first publish lands;
   multi-platform consumers should wait until `complete: true` in the manifest
   (or until the win32 asset appears).

Upstream pins are never silently swapped inside downstream apps.

## Reproducibility

Archive timestamps are normalized and entries ordered deterministically.
Checksums cover the final bytes. The source bundle holds build definitions and
source snapshots used for that runtime.

The AC-4 smoke fixture URL and hash live in
[`fixtures/ac4-smoke.json`](fixtures/ac4-smoke.json). CI downloads it into a
temp dir; the media file is not redistributed by this repo.

## License

Build automation in this repository is MIT.

Runtime binaries follow combined upstream terms. The current profile is
`AGPL-3.0-or-later`, does not enable nonfree components, and ships license texts
plus corresponding source. Read [`NOTICE.md`](NOTICE.md) before redistributing
or embedding.

mpv and LibreMPEG are independent projects. MpvLibre Runtime is not an official
release of either.
