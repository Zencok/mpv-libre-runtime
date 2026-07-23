#!/bin/sh
# Windows cross-build entrypoint.
# BUILD_MODE:
#   full    — llvm + all deps + librempeg + mpv (cold path / local default)
#   deps    — llvm + codec/UI deps only (GHCR deps image)
#   runtime — librempeg + mpv only (expects deps already present under /build)
set -eu

: "${BUILDER_REPOSITORY:?BUILDER_REPOSITORY is required}"
: "${BUILDER_COMMIT:?BUILDER_COMMIT is required}"
: "${MPV_REPOSITORY:?MPV_REPOSITORY is required}"
: "${MPV_COMMIT:?MPV_COMMIT is required}"
: "${LIBREMPEG_REPOSITORY:?LIBREMPEG_REPOSITORY is required}"
: "${LIBREMPEG_COMMIT:?LIBREMPEG_COMMIT is required}"
: "${RUNTIME_VERSION:?RUNTIME_VERSION is required}"

BUILD_MODE=${BUILD_MODE:-full}
case "${BUILD_MODE}" in
    full|deps|runtime) ;;
    *) echo "Unsupported BUILD_MODE=${BUILD_MODE}" >&2; exit 2 ;;
esac

SOURCE_ROOT=/build/mingw-cmake-env
BUILD_ROOT=/build/output
RUNTIME_ROOT="${BUILD_ROOT}/packages/mpv-runtime"
OUTPUT_ROOT=/workspace/artifacts
PACKAGE_SRC=/workspace/build/windows-x64/packages
ARCHIVE_NAME=mpv-libre-runtime-win32-x64.7z
SOURCE_ARCHIVE_NAME=mpv-libre-runtime-sources.tar.xz
# Prefer a dedicated /ccache mount so host volumes for /build do not hide it.
CCACHE_DIR=${CCACHE_DIR:-/ccache}
export CCACHE_DIR
export CCACHE_CONFIGPATH=${CCACHE_CONFIGPATH:-/etc/ccache.conf}

# Prefer explicit MAKEJOBS; otherwise use available CPUs (cap at 16 for RAM).
if [ -z "${MAKEJOBS:-}" ] || [ "${MAKEJOBS}" = "0" ]; then
    if command -v nproc >/dev/null 2>&1; then
        MAKEJOBS=$(nproc)
    else
        MAKEJOBS=4
    fi
fi
if [ "${MAKEJOBS}" -gt 16 ]; then
    MAKEJOBS=16
fi
export MAKEJOBS

mkdir -p "${CCACHE_DIR}" "${BUILD_ROOT}" "${OUTPUT_ROOT}"

log() {
    printf '==> %s\n' "$*"
}

ccache_stats() {
    if command -v ccache >/dev/null 2>&1; then
        log "ccache stats"
        ccache --show-stats 2>/dev/null || true
        ccache --print-stats 2>/dev/null || true
    fi
}

prepare_builder() {
    if [ -d "${SOURCE_ROOT}/.git" ]; then
        log "updating mingw-cmake-env checkout to ${BUILDER_COMMIT}"
        git -C "${SOURCE_ROOT}" fetch --depth=1 origin "${BUILDER_COMMIT}"
        git -C "${SOURCE_ROOT}" checkout --detach --force "${BUILDER_COMMIT}" 2>/dev/null \
            || git -C "${SOURCE_ROOT}" reset --hard "${BUILDER_COMMIT}"
    elif [ -d "${SOURCE_ROOT}" ]; then
        # Deps image strips .git to shrink layers; tree must already match pin.
        log "using vendored mingw-cmake-env tree (no .git) at ${SOURCE_ROOT}"
        if [ -f "${SOURCE_ROOT}/.builder-commit" ]; then
            pinned=$(cat "${SOURCE_ROOT}/.builder-commit")
            if [ "${pinned}" != "${BUILDER_COMMIT}" ]; then
                echo "Vendored builder commit ${pinned} != required ${BUILDER_COMMIT}" >&2
                echo "Rebuild the MinGW deps image for this builder pin." >&2
                exit 1
            fi
        else
            log "warning: no .builder-commit pin file; assuming tree matches ${BUILDER_COMMIT}"
        fi
    else
        log "cloning mingw-cmake-env"
        git clone --filter=blob:none "${BUILDER_REPOSITORY}" "${SOURCE_ROOT}"
        git -C "${SOURCE_ROOT}" fetch --depth=1 origin "${BUILDER_COMMIT}"
        git -C "${SOURCE_ROOT}" checkout --detach --force "${BUILDER_COMMIT}" 2>/dev/null \
            || git -C "${SOURCE_ROOT}" reset --hard "${BUILDER_COMMIT}"
    fi
    mkdir -p "${SOURCE_ROOT}/packages"
    cp "${PACKAGE_SRC}/librempeg.cmake" "${SOURCE_ROOT}/packages/librempeg.cmake"
    cp "${PACKAGE_SRC}/mpv.cmake" "${SOURCE_ROOT}/packages/mpv.cmake"
}

# Parse DEPENDS= lists from our package recipes (excludes librempeg/mpv themselves).
load_deps_targets() {
    DEPS_TARGETS=$(
        awk '
            BEGIN { dep = 0 }
            $1 == "DEPENDS" {
                dep = 1
                for (i = 2; i <= NF; i++) emit($i)
                next
            }
            dep {
                if ($0 ~ /GIT_REPOSITORY|UPDATE_COMMAND|CONFIGURE_COMMAND|CMAKE_ARGS|BUILD_COMMAND|INSTALL_COMMAND|LOG_|DOWNLOAD_|PATCH_|SOURCE_SUBDIR|URL |URL_HASH|BINARY_DIR|SOURCE_DIR/) {
                    dep = 0
                    next
                }
                for (i = 1; i <= NF; i++) emit($i)
            }
            function emit(tok) {
                gsub(/[^A-Za-z0-9_-]/, "", tok)
                if (tok == "" || tok == "DEPENDS") return
                if (tok == "librempeg" || tok == "mpv") return
                print tok
            }
        ' "${PACKAGE_SRC}/librempeg.cmake" "${PACKAGE_SRC}/mpv.cmake" \
        | sort -u
    )
    if [ -z "${DEPS_TARGETS}" ]; then
        echo "Failed to parse DEPENDS targets from package cmake files" >&2
        exit 1
    fi
    log "dep targets: $(echo "${DEPS_TARGETS}" | tr '\n' ' ')"
}

configure_tree() {
    log "cmake configure (${BUILD_MODE}) jobs=${MAKEJOBS}"
    # Runtime seals prebuilt dep steps after configure. Allowing Ninja to
    # re-run CMake mid-build would regenerate those scripts and undo the seal.
    set -- \
        -S "${SOURCE_ROOT}" \
        -B "${BUILD_ROOT}" \
        -G Ninja \
        -DCPUTUNE=x86-64 \
        -DMAKEJOBS="${MAKEJOBS}"
    if [ "${BUILD_MODE}" = "runtime" ]; then
        set -- "$@" -DCMAKE_SUPPRESS_REGENERATION=ON
    fi
    cmake "$@"
}

fix_harfbuzz_if_needed() {
    HARFBUZZ_PREFIX="${BUILD_ROOT}/packages/harfbuzz-prefix/src"
    if grep -q '"full": "1\.8\.' \
        "${HARFBUZZ_PREFIX}/harfbuzz-build/meson-info/meson-info.json" 2>/dev/null; then
        log "resetting incompatible harfbuzz build tree"
        rm -rf "${HARFBUZZ_PREFIX}/harfbuzz-build"
        rm -f \
            "${HARFBUZZ_PREFIX}/harfbuzz-stamp/harfbuzz-force-meson-configure" \
            "${HARFBUZZ_PREFIX}/harfbuzz-stamp/harfbuzz-configure" \
            "${HARFBUZZ_PREFIX}/harfbuzz-stamp/harfbuzz-build" \
            "${HARFBUZZ_PREFIX}/harfbuzz-stamp/harfbuzz-install"
    fi
}

build_llvm() {
    log "building llvm toolchain target"
    cmake --build "${BUILD_ROOT}" --target llvm --parallel "${MAKEJOBS}"
}

build_deps() {
    load_deps_targets
    log "building MinGW dependency targets"
    set --
    # shellcheck disable=SC2086
    for target in ${DEPS_TARGETS}; do
        set -- "$@" --target "${target}"
    done
    # shellcheck disable=SC2068
    cmake --build "${BUILD_ROOT}" --parallel "${MAKEJOBS}" $@
}

invalidate_runtime_packages() {
    # Force ExternalProject to rebuild when pins change; leave other deps intact.
    rm -rf \
        "${BUILD_ROOT}/packages/librempeg-prefix" \
        "${BUILD_ROOT}/packages/mpv-prefix" \
        "${BUILD_ROOT}/packages/librempeg-stamp" \
        "${BUILD_ROOT}/packages/mpv-stamp" \
        "${BUILD_ROOT}/packages/mpv-runtime"
}

# After cmake reconfigure, Ninja re-runs ExternalProject steps for deps because
# stamp inputs (e.g. *-gitinfo.txt) are regenerated. The deps image already has
# those packages installed under MINGW_INSTALL_PREFIX; re-running is wrong and
# fails hard on slimmed trees (no .git → libzimg `git clean` / force-update die).
#
# Seal strategy (must survive until cmake --build):
#  1. Rewrite dep ExternalProject step scripts to no-ops.
#  2. Patch build.ninja COMMAND lines for dep packages to `cmake -E true`
#     (script no-ops alone are not enough if Ninja still invokes real rules).
#  3. Refresh stamp files / *-complete markers.
seal_prebuilt_deps() {
    log "sealing prebuilt dependency ExternalProject steps (runtime)"
    sealed=0
    noop_cmake="${BUILD_ROOT}/mpv-libre-seal-noop.cmake"
    printf '%s\n' \
        'cmake_minimum_required(VERSION 3.16)' \
        '# sealed: prebuilt MinGW dep — skip ExternalProject step' \
        > "${noop_cmake}"

    for prefix in "${BUILD_ROOT}/packages"/*-prefix; do
        [ -d "${prefix}" ] || continue
        pkg=$(basename "${prefix}" -prefix)
        case "${pkg}" in
            librempeg|mpv|mpv-runtime) continue ;;
        esac

        # No-op step scripts (cmake -P drivers).
        find "${prefix}" -type f -name '*.cmake' 2>/dev/null \
            | while read -r script; do
                case "${script}" in
                    *gitinfo*|*patch-info*|*update-info*) continue ;;
                esac
                if grep -q 'execute_process' "${script}" 2>/dev/null; then
                    cp "${noop_cmake}" "${script}"
                fi
            done

        find "${prefix}" -type d -name '*-stamp' 2>/dev/null \
            | while read -r stamp_dir; do
                stamp_pkg=$(basename "${stamp_dir}" | sed 's/-stamp$//')
                for step in mkdir download update patch configure build install done \
                    force-update force-meson-configure force-git-patch; do
                    touch "${stamp_dir}/${stamp_pkg}-${step}" 2>/dev/null || true
                    touch "${stamp_dir}/${stamp_pkg}-${step}-" 2>/dev/null || true
                done
                find "${stamp_dir}" -type f -exec touch {} + 2>/dev/null || true
            done

        mkdir -p "${BUILD_ROOT}/packages/CMakeFiles"
        touch "${BUILD_ROOT}/packages/CMakeFiles/${pkg}-complete" 2>/dev/null || true
        sealed=$((sealed + 1))
    done

    # Rewrite Ninja COMMANDs for every non-runtime package prefix. This is the
    # hard guarantee: even if a step is dirty, it becomes a no-op edge.
    if [ -f "${BUILD_ROOT}/build.ninja" ]; then
        log "patching build.ninja commands for prebuilt deps"
        # BusyBox awk: blank COMMAND lines that reference a sealed package path.
        # Keep librempeg/mpv/mpv-runtime commands intact.
        awk '
            BEGIN { skip = 0 }
            /^[[:space:]]*COMMAND = / {
                line = $0
                if (line ~ /packages\/librempeg-prefix/ \
                    || line ~ /packages\/mpv-prefix/ \
                    || line ~ /packages\/mpv-runtime/ \
                    || line ~ /packages\/CMakeFiles\/librempeg/ \
                    || line ~ /packages\/CMakeFiles\/mpv[^-]/) {
                    print
                    next
                }
                if (line ~ /packages\/[A-Za-z0-9_.+-]+-prefix/ \
                    || line ~ /packages\/CMakeFiles\/[A-Za-z0-9_.+-]+-complete/) {
                    sub(/COMMAND = .*/, "COMMAND = /usr/bin/cmake -E true")
                    print
                    next
                }
                print
                next
            }
            { print }
        ' "${BUILD_ROOT}/build.ninja" > "${BUILD_ROOT}/build.ninja.sealed"
        mv "${BUILD_ROOT}/build.ninja.sealed" "${BUILD_ROOT}/build.ninja"
    fi

    # Sanity: a known dep install driver must be a no-op after sealing.
    sample=$(find "${BUILD_ROOT}/packages" -path '*/libzimg-stamp/*install*impl.cmake' 2>/dev/null | head -n1 || true)
    if [ -n "${sample}" ] && ! grep -q 'sealed: prebuilt' "${sample}" 2>/dev/null; then
        echo "seal_prebuilt_deps failed: ${sample} was not no-op'd" >&2
        exit 1
    fi
    log "sealed ${sealed} prebuilt dependency package(s)"
}

slim_deps_tree() {
    log "slimming /build for image payload"
    # Keep .git and object archives: runtime reconfigure + force_rebuild_git /
    # libzimg INSTALL_COMMAND (`git clean`) need a recoverable tree if a dep
    # edge is ever re-run. Installed prefixes under install/ stay intact.

    # Drop package download caches only (do NOT delete installed *.exe tools).
    find "${BUILD_ROOT}" -type d \( \
        -name download -o -name downloads -o -name '.cache' -o -name tmp \
    \) 2>/dev/null | while read -r d; do
        # Preserve ExternalProject tmp/ scripts used by mkdir steps.
        case "${d}" in
            */packages/*/tmp) continue ;;
        esac
        rm -rf "${d}"
    done
    find "${BUILD_ROOT}" -type f \( \
        -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o \
        -name '*.tar.xz' -o -name '*.tar.bz2' -o -name '*.zip' -o -name '*.7z' \
    \) -delete 2>/dev/null || true
    # Drop bulky intermediate objects but keep static libs (.a) and libtool
    # outputs needed for a re-install edge.
    find "${BUILD_ROOT}/packages" -type d \( -name '*-build' -o -name 'src' \) 2>/dev/null \
        | while read -r d; do
            find "${d}" -type f \( -name '*.o' -o -name '*.obj' -o -name '*.lo' \) \
                ! -path '*/install/*' -delete 2>/dev/null || true
        done
    find "${BUILD_ROOT}" -type f \( -name 'CMakeOutput.log' -o -name 'CMakeError.log' \) \
        -delete 2>/dev/null || true
    if command -v ccache >/dev/null 2>&1; then
        ccache -M 1.5G 2>/dev/null || true
        ccache --cleanup 2>/dev/null || true
    fi
    du -sh /build "${CCACHE_DIR}" 2>/dev/null || true
}

dump_ep_failure_logs() {
    log "dumping recent ExternalProject failure logs (if any)"
    find "${BUILD_ROOT}/packages" -type f \( \
        -name '*-err.log' -o -name '*-out.log' \
    \) -size +0 2>/dev/null \
        | sort \
        | tail -n 40 \
        | while read -r f; do
            printf '---- %s ----\n' "${f}"
            tail -n 40 "${f}" 2>/dev/null || true
        done
}

build_runtime_packages() {
    # Caller is responsible for invalidate + reconfigure + seal in runtime mode.
    log "building librempeg + mpv"
    if ! cmake --build "${BUILD_ROOT}" --target librempeg --parallel "${MAKEJOBS}"; then
        dump_ep_failure_logs
        return 1
    fi
    if ! cmake --build "${BUILD_ROOT}" --target mpv --parallel "${MAKEJOBS}"; then
        dump_ep_failure_logs
        return 1
    fi
}

package_runtime() {
    test -s "${RUNTIME_ROOT}/libmpv-2.dll"
    test -s "${RUNTIME_ROOT}/ffmpeg.exe"
    test -s "${RUNTIME_ROOT}/ffprobe.exe"
    rm -rf "${RUNTIME_ROOT}/include"
    rm -f "${RUNTIME_ROOT}/libmpv.dll.a"
    mkdir -p "${RUNTIME_ROOT}/licenses/librempeg" "${OUTPUT_ROOT}"
    cp "${BUILD_ROOT}/packages/librempeg-prefix/src/librempeg/COPYING.AGPLv3" \
        "${RUNTIME_ROOT}/licenses/librempeg/COPYING.AGPLv3"
    cp "${BUILD_ROOT}/packages/librempeg-prefix/src/librempeg/COPYING.GPLv3" \
        "${RUNTIME_ROOT}/licenses/librempeg/COPYING.GPLv3"
    cp "${BUILD_ROOT}/packages/librempeg-prefix/src/librempeg/LICENSE.md" \
        "${RUNTIME_ROOT}/licenses/librempeg/LICENSE.md"
    cp /workspace/NOTICE.md "${RUNTIME_ROOT}/NOTICE.md"
    cat > "${RUNTIME_ROOT}/runtime.json" <<EOF
{
  "schemaVersion": 1,
  "name": "mpv-libre-runtime",
  "version": "${RUNTIME_VERSION}",
  "engine": "libmpv",
  "mediaBackend": "librempeg",
  "license": "AGPL-3.0-or-later",
  "decoders": ["ac4"],
  "platform": "win32-x64",
  "sourceCommits": {
    "builder": "${BUILDER_COMMIT}",
    "mpv": "${MPV_COMMIT}",
    "librempeg": "${LIBREMPEG_COMMIT}"
  }
}
EOF

    rm -f "${OUTPUT_ROOT}/${ARCHIVE_NAME}"
    (
        cd "${RUNTIME_ROOT}"
        # -mx=5 is far cheaper than -mx=9 with negligible size impact for CI.
        7z a -t7z -mx=5 -mmt=on -mtm=off -mta=off -mtc=off \
            "${OUTPUT_ROOT}/${ARCHIVE_NAME}" .
    )

    if [ "${CREATE_SOURCE_BUNDLE:-0}" = "1" ]; then
        sh /workspace/build/windows-x64/collect-sources.sh \
            "${SOURCE_ROOT}" \
            "${BUILD_ROOT}" \
            "${OUTPUT_ROOT}/${SOURCE_ARCHIVE_NAME}"
    fi
}

log "Windows build mode=${BUILD_MODE} jobs=${MAKEJOBS}"
ccache_stats
prepare_builder
fix_harfbuzz_if_needed

# Always reconfigure after copying package recipes and applying runtime env pins.
# The deps image is configured with dummy MPV/LIBREMPEG commits; ExternalProject
# expands $ENV{…} at configure time, so skipping cmake here would keep fake GIT_TAGs.
configure_tree

case "${BUILD_MODE}" in
    deps)
        build_llvm
        build_deps
        invalidate_runtime_packages
        printf '%s\n' "${BUILDER_COMMIT}" > "${SOURCE_ROOT}/.builder-commit"
        slim_deps_tree
        log "deps image payload ready under /build"
        ;;
    runtime)
        # 1) First configure above picks real MPV/LIBREMPEG pins but dirties deps.
        # 2) Seal dep ExternalProject scripts (no-op) so Ninja won't rebuild them.
        # 3) Drop librempeg/mpv trees so they rebuild from the new pins.
        # 4) Reconfigure recreates librempeg/mpv EP metadata (cfgcmd/stamps);
        #    that would also un-seal deps, so seal again.
        # 5) Build only librempeg + mpv against the preinstalled MinGW prefix.
        seal_prebuilt_deps
        invalidate_runtime_packages
        configure_tree
        seal_prebuilt_deps
        build_runtime_packages
        package_runtime
        ;;
    full)
        build_llvm
        build_deps
        invalidate_runtime_packages
        build_runtime_packages
        package_runtime
        ;;
esac

ccache_stats
log "done (${BUILD_MODE})"
