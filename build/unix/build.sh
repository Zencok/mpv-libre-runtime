#!/usr/bin/env bash
# Build a portable libmpv + LibreMPEG runtime for one Unix target.
# Targets: linux-x64 | linux-arm64 | darwin-x64 | darwin-arm64
set -euo pipefail

: "${RUNTIME_TARGET:?RUNTIME_TARGET is required}"
: "${RUNTIME_ARTIFACT:?RUNTIME_ARTIFACT is required}"
: "${MPV_REPOSITORY:?MPV_REPOSITORY is required}"
: "${MPV_COMMIT:?MPV_COMMIT is required}"
: "${LIBREMPEG_REPOSITORY:?LIBREMPEG_REPOSITORY is required}"
: "${LIBREMPEG_COMMIT:?LIBREMPEG_COMMIT is required}"
: "${LIBPLACEBO_REPOSITORY:?LIBPLACEBO_REPOSITORY is required}"
: "${LIBPLACEBO_COMMIT:?LIBPLACEBO_COMMIT is required}"

case "${RUNTIME_TARGET}" in
    linux-x64|linux-arm64|darwin-x64|darwin-arm64) ;;
    *) echo "Unsupported target: ${RUNTIME_TARGET}" >&2; exit 2 ;;
esac

ROOT=$(pwd)
WORK_ROOT="${ROOT}/.build/${RUNTIME_TARGET}"
SOURCE_ROOT="${WORK_ROOT}/sources"
PREFIX="${WORK_ROOT}/prefix"
RUNTIME_ROOT="${WORK_ROOT}/runtime"
ARTIFACT_ROOT="${ROOT}/artifacts"
MPV_SOURCE="${SOURCE_ROOT}/mpv"
LIBREMPEG_SOURCE="${SOURCE_ROOT}/librempeg"
LIBPLACEBO_SOURCE="${SOURCE_ROOT}/libplacebo"
MPV_BUILD="${WORK_ROOT}/mpv-build"
LIBPLACEBO_BUILD="${WORK_ROOT}/libplacebo-build"
# Bump when meson options / link strategy change so cached trees reconfigure cleanly.
BUILD_PROFILE=unix-runtime-v5

is_linux=0
is_darwin=0
if [[ "${RUNTIME_TARGET}" == linux-* ]]; then
    is_linux=1
elif [[ "${RUNTIME_TARGET}" == darwin-* ]]; then
    is_darwin=1
fi

log() {
    printf '==> %s\n' "$*"
}

checkout_source() {
    name=$1
    repository=$2
    commit=$3
    destination="${SOURCE_ROOT}/${name}"
    if [ ! -d "${destination}/.git" ]; then
        git clone --filter=blob:none --no-checkout "${repository}" "${destination}"
    fi
    git -C "${destination}" fetch --depth=1 origin "${commit}"
    git -C "${destination}" checkout --detach --force "${commit}"
    if [ "${name}" = "libplacebo" ]; then
        git -C "${destination}" submodule update --init --depth=1 \
            3rdparty/fast_float 3rdparty/glad 3rdparty/jinja 3rdparty/markupsafe \
            3rdparty/Vulkan-Headers
    fi
}

# Fresh setup when the build profile changes; reconfigure otherwise.
meson_configure() {
    build_directory=$1
    source_directory=$2
    shift 2
    stamp="${build_directory}/.mpv-libre-profile"
    if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${BUILD_PROFILE}" ] \
        && [ -f "${build_directory}/meson-private/coredata.dat" ]; then
        meson setup --reconfigure "${build_directory}" "${source_directory}" "$@"
    else
        rm -rf "${build_directory}"
        meson setup "${build_directory}" "${source_directory}" "$@"
        printf '%s\n' "${BUILD_PROFILE}" > "${stamp}"
    fi
}

# Meson prefer_static=false still embeds absolute /usr/lib/**/*.a paths on some
# Ubuntu images. Shared system libs are required for a PIC-safe libmpv.so.
#
# Ninja treats build-edge inputs as files, so system .a paths must be *removed*
# from build inputs (not rewritten to -lfoo — that becomes a fake target).
# LINK_ARGS may safely use -lfoo instead.
rewrite_system_static_archives() {
    local ninja_file=$1
    python3 - "${ninja_file}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
# Matches /usr/lib/.../libfoo.a and /usr/lib/gcc/.../libatomic.a etc.
sys_static = re.compile(
    r"(?<![\w./-])(/usr/(?:local/)?lib(?:/[^/\s]+)*?/lib([A-Za-z0-9+._-]+)\.a)\b"
)
out = []
stats = {"removed_from_inputs": 0, "rewrote_link_args": 0}
pending_libs = []

for line in lines:
    if line.startswith("build "):
        target = line.split(":", 1)[0]
        if ".so" in target or "libmpv" in target:
            libs = []

            def drop(match, _libs=libs, _stats=stats):
                _stats["removed_from_inputs"] += 1
                _libs.append(match.group(2))
                return ""

            line = sys_static.sub(drop, line)
            line = re.sub(r"[ \t]{2,}", " ", line)
            pending_libs = libs
            out.append(line)
            continue

    if re.match(r"^  LINK_ARGS\s*=", line):
        def to_flag(match, _stats=stats):
            _stats["rewrote_link_args"] += 1
            return "-l" + match.group(2)

        line = sys_static.sub(to_flag, line)
        if pending_libs:
            missing = []
            for name in pending_libs:
                flag = "-l" + name
                if flag not in line:
                    missing.append(flag)
            if missing:
                line = line.rstrip("\n")
                if not line.endswith(" "):
                    line += " "
                line += " ".join(missing) + "\n"
            pending_libs = []
        out.append(line)
        continue

    pending_libs = []
    out.append(line)

path.write_text("".join(out), encoding="utf-8")
print(
    "linux link fixup: removed {removed} system .a build input(s), "
    "rewrote {rewrote} LINK_ARGS archive(s) in {path}".format(
        removed=stats["removed_from_inputs"],
        rewrote=stats["rewrote_link_args"],
        path=path,
    )
)
PY
}

copy_linux_runtime_dependencies() {
    library=$1
    mkdir -p "${RUNTIME_ROOT}/licenses/system"

    # Ensure C++ runtime is always present: static libplacebo needs libstdc++.
    ensure_linux_cxx_runtime

    mapfile -t dependencies < <(
        ldd "${library}" |
            awk '/=> \// { print $3 } /^[[:space:]]*\/.* \(/ { print $1 }' |
            sort -u
    )
    for dependency in "${dependencies[@]}"; do
        [ -e "${dependency}" ] || continue
        filename=$(basename "${dependency}")
        case "${filename}" in
            ld-linux*.so*|ld-*.so|libc.so.*|libdl.so.*|libm.so.*|libpthread.so.*|\
                libresolv.so.*|librt.so.*|libutil.so.*)
                continue
                ;;
        esac
        cp -L "${dependency}" "${RUNTIME_ROOT}/lib/${filename}"
        package=$(dpkg-query -S "${dependency}" 2>/dev/null |
            sed -n '1s/: .*//p' || true)
        package=${package%%:*}
        if [ -n "${package}" ] && [ -f "/usr/share/doc/${package}/copyright" ]; then
            cp "/usr/share/doc/${package}/copyright" \
                "${RUNTIME_ROOT}/licenses/system/${package}.copyright"
        fi
    done

    for dependency in "${RUNTIME_ROOT}"/lib/*.so*; do
        [ -e "${dependency}" ] || continue
        if [ ! -L "${dependency}" ]; then
            patchelf --set-rpath '$ORIGIN' "${dependency}"
        fi
    done
    # ffmpeg/ffprobe may also need rpath when they pull shared deps later.
    for binary in ffmpeg ffprobe; do
        if [ -f "${RUNTIME_ROOT}/${binary}" ]; then
            patchelf --set-rpath '$ORIGIN/lib' "${RUNTIME_ROOT}/${binary}" || true
        fi
    done

    if ! LD_LIBRARY_PATH="${RUNTIME_ROOT}/lib" ldd "${library}" |
        awk '/not found/ { missing = 1; print } END { exit missing }'; then
        echo "Linux runtime has unresolved shared libraries" >&2
        LD_LIBRARY_PATH="${RUNTIME_ROOT}/lib" ldd "${library}" || true
        exit 1
    fi
}

ensure_linux_cxx_runtime() {
    local candidate
    for candidate in \
        "/usr/lib/$(uname -m)-linux-gnu/libstdc++.so.6" \
        /usr/lib64/libstdc++.so.6 \
        /lib/$(uname -m)-linux-gnu/libstdc++.so.6 \
        /lib64/libstdc++.so.6; do
        if [ -e "${candidate}" ]; then
            cp -L "${candidate}" "${RUNTIME_ROOT}/lib/libstdc++.so.6"
            break
        fi
    done
    for candidate in \
        "/usr/lib/$(uname -m)-linux-gnu/libgcc_s.so.1" \
        /usr/lib64/libgcc_s.so.1 \
        /lib/$(uname -m)-linux-gnu/libgcc_s.so.1 \
        /lib64/libgcc_s.so.1; do
        if [ -e "${candidate}" ]; then
            cp -L "${candidate}" "${RUNTIME_ROOT}/lib/libgcc_s.so.1"
            break
        fi
    done
    test -e "${RUNTIME_ROOT}/lib/libstdc++.so.6"
    test -e "${RUNTIME_ROOT}/lib/libgcc_s.so.1"
}

is_system_darwin_lib() {
    case "$1" in
        /System/*|/usr/lib/*|/usr/lib/*/*)
            return 0
            ;;
        /Library/Developer/*|/Applications/Xcode*.app/*)
            return 0
            ;;
        @rpath/*|@loader_path/*|@executable_path/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Portable for macOS /bin/bash 3.2 (no associative arrays).
copy_darwin_runtime_dependencies() {
    library=$1
    local worklist="${WORK_ROOT}/.darwin-deps-worklist"
    local seen_file="${WORK_ROOT}/.darwin-deps-seen"
    local current dep filename dest

    : > "${worklist}"
    : > "${seen_file}"
    printf '%s\n' "${library}" >> "${worklist}"

    while [ -s "${worklist}" ]; do
        current=$(head -n 1 "${worklist}")
        tail -n +2 "${worklist}" > "${worklist}.rest"
        mv "${worklist}.rest" "${worklist}"
        if grep -Fxq -- "${current}" "${seen_file}"; then
            continue
        fi
        printf '%s\n' "${current}" >> "${seen_file}"

        while IFS= read -r dep; do
            [ -n "${dep}" ] || continue
            if is_system_darwin_lib "${dep}"; then
                continue
            fi
            if [ ! -e "${dep}" ]; then
                echo "Missing macOS dependency: ${dep}" >&2
                exit 1
            fi
            filename=$(basename "${dep}")
            dest="${RUNTIME_ROOT}/lib/${filename}"
            if [ ! -e "${dest}" ]; then
                cp -L "${dep}" "${dest}"
                chmod u+w "${dest}"
            fi
            printf '%s\n' "${dep}" >> "${worklist}"
        done <<EOF
$(otool -L "${current}" | awk 'NR > 1 { print $1 }')
EOF
    done

    # Rewrite install names to @loader_path relative layout.
    for current in "${RUNTIME_ROOT}"/lib/*; do
        [ -f "${current}" ] || continue
        chmod u+w "${current}"
        filename=$(basename "${current}")
        install_name_tool -id "@loader_path/${filename}" "${current}" 2>/dev/null || true
        otool -L "${current}" | awk 'NR > 1 { print $1 }' | while IFS= read -r dep; do
            [ -n "${dep}" ] || continue
            if is_system_darwin_lib "${dep}"; then
                continue
            fi
            filename=$(basename "${dep}")
            if [ -e "${RUNTIME_ROOT}/lib/${filename}" ]; then
                install_name_tool -change "${dep}" "@loader_path/${filename}" "${current}" \
                    2>/dev/null || true
            fi
        done
    done

    for binary in ffmpeg ffprobe; do
        if [ ! -f "${RUNTIME_ROOT}/${binary}" ]; then
            continue
        fi
        chmod u+w "${RUNTIME_ROOT}/${binary}"
        otool -L "${RUNTIME_ROOT}/${binary}" | awk 'NR > 1 { print $1 }' | while IFS= read -r dep; do
            [ -n "${dep}" ] || continue
            if is_system_darwin_lib "${dep}"; then
                continue
            fi
            filename=$(basename "${dep}")
            if [ -e "${RUNTIME_ROOT}/lib/${filename}" ]; then
                install_name_tool -change "${dep}" "@loader_path/lib/${filename}" \
                    "${RUNTIME_ROOT}/${binary}" 2>/dev/null || true
            fi
        done
    done

    rm -f "${worklist}" "${seen_file}" "${worklist}.bak"
}

smoke_dlopen_libmpv() {
    local library=$1
    local probe_root
    probe_root=$(mktemp -d)
    cat > "${probe_root}/probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    if (!dlsym(library, "mpv_create") || !dlsym(library, "mpv_client_api_version")) {
        fprintf(stderr, "required libmpv symbols missing\n");
        return 3;
    }
    dlclose(library);
    return 0;
}
EOF
    if [ "${is_darwin}" -eq 1 ]; then
        cc -O2 -o "${probe_root}/probe" "${probe_root}/probe.c"
        DYLD_LIBRARY_PATH="${RUNTIME_ROOT}/lib" "${probe_root}/probe" "${library}"
    else
        cc -O2 -o "${probe_root}/probe" "${probe_root}/probe.c" -ldl
        LD_LIBRARY_PATH="${RUNTIME_ROOT}/lib" "${probe_root}/probe" "${library}"
    fi
    rm -rf "${probe_root}"
}

log "Building ${RUNTIME_TARGET} (${BUILD_PROFILE})"
rm -rf "${RUNTIME_ROOT}"
mkdir -p "${SOURCE_ROOT}" "${PREFIX}" "${RUNTIME_ROOT}/lib" "${ARTIFACT_ROOT}"
checkout_source librempeg "${LIBREMPEG_REPOSITORY}" "${LIBREMPEG_COMMIT}"
checkout_source libplacebo "${LIBPLACEBO_REPOSITORY}" "${LIBPLACEBO_COMMIT}"
checkout_source mpv "${MPV_REPOSITORY}" "${MPV_COMMIT}"

# C++ runtime: libstdc++ on Linux, libc++ on Apple platforms.
if [ "${is_darwin}" -eq 1 ]; then
    CXX_LIB="-lc++"
else
    CXX_LIB="-lstdc++"
fi

log "Configuring LibreMPEG"
pushd "${LIBREMPEG_SOURCE}" >/dev/null
./configure \
    --prefix="${PREFIX}" \
    --enable-gpl \
    --enable-version3 \
    --enable-pic \
    --enable-static \
    --disable-shared \
    --disable-autodetect \
    --disable-debug \
    --disable-doc \
    --disable-ffplay \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --enable-ffmpeg \
    --enable-ffprobe \
    --enable-runtime-cpudetect \
    --enable-agpl \
    --extra-libs="${CXX_LIB} -lm"
make -j"${MAKEJOBS:-4}"
make install
popd >/dev/null

log "Configuring libplacebo (static, PIC)"
meson_configure "${LIBPLACEBO_BUILD}" "${LIBPLACEBO_SOURCE}" \
    --prefix="${PREFIX}" \
    --libdir=lib \
    --buildtype=release \
    --default-library=static \
    --auto-features=disabled \
    -Db_staticpic=true \
    -Ddemos=false \
    -Dgl-proc-addr=enabled \
    -Dglslang=disabled \
    -Dopengl=enabled \
    -Dshaderc=disabled \
    -Dtests=false \
    -Dvulkan=enabled \
    -Dvk-proc-addr=disabled
meson compile -C "${LIBPLACEBO_BUILD}" -j "${MAKEJOBS:-4}"
meson install -C "${LIBPLACEBO_BUILD}"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export PATH="${PREFIX}/bin:${PATH}"
# libplacebo / fast_float C++ symbols must resolve in libmpv.
export LDFLAGS="${LDFLAGS:-} ${CXX_LIB}"
export LIBS="${LIBS:-} ${CXX_LIB}"

PLATFORM_OPTIONS=()
LINK_OPTIONS=()
COMMON_OPTIONS=(
    --prefix="${PREFIX}"
    --libdir=lib
    --buildtype=release
    --default-library=shared
    --auto-features=disabled
    -Dbuild-date=false
    -Dcplayer=false
    -Dgl=enabled
    -Dlibmpv=true
    -Dmanpage-build=disabled
    -Dplain-gl=enabled
    "-Dc_link_args=${CXX_LIB}"
    "-Dcpp_link_args=${CXX_LIB}"
)

if [ "${is_linux}" -eq 1 ]; then
    # Shared system deps + static self-built media stack.
    PLATFORM_OPTIONS+=("-Dalsa=enabled" "-Dpulse=enabled")
    LINK_OPTIONS+=("-Dprefer_static=false")
else
    # Full macOS libmpv surface: Cocoa + Swift + cocoa-cb OpenGL backend.
    if ! command -v xcrun >/dev/null 2>&1; then
        echo "xcrun is required for the macOS Swift build" >&2
        exit 1
    fi
    if ! xcrun -find swiftc >/dev/null 2>&1; then
        echo "swiftc is required for cocoa/swift libmpv on macOS" >&2
        exit 1
    fi
    # view.swift references MetalLayer, which is only compiled when vulkan+swift
    # are enabled (metal_layer.swift). Cocoa without vulkan fails the Swift build.
    PLATFORM_OPTIONS+=(
        "-Dcoreaudio=enabled"
        "-Dcocoa=enabled"
        "-Dswift-build=enabled"
        "-Dgl-cocoa=enabled"
        "-Dmacos-cocoa-cb=enabled"
        "-Dvulkan=enabled"
        "-Dvideotoolbox-gl=enabled"
        "-Dvideotoolbox-pl=enabled"
        "-Dmacos-media-player=enabled"
    )
    # Prefer static Homebrew archives when present for a more self-contained dylib.
    LINK_OPTIONS+=("-Dprefer_static=true")
fi

log "Configuring mpv/libmpv"
# Always rebuild the ninja graph for mpv so link strategy cannot stick from an
# older profile (stale absolute .a paths were the linux-x64 failure mode).
rm -rf "${MPV_BUILD}"
meson setup "${MPV_BUILD}" "${MPV_SOURCE}" \
    "${COMMON_OPTIONS[@]}" \
    "${LINK_OPTIONS[@]}" \
    "${PLATFORM_OPTIONS[@]}"
printf '%s\n' "${BUILD_PROFILE}" > "${MPV_BUILD}/.mpv-libre-profile"

if [ "${is_linux}" -eq 1 ]; then
    rewrite_system_static_archives "${MPV_BUILD}/build.ninja"
fi

log "Compiling libmpv"
meson compile -C "${MPV_BUILD}" -j "${MAKEJOBS:-4}"
meson install -C "${MPV_BUILD}"

cp "${PREFIX}/bin/ffmpeg" "${PREFIX}/bin/ffprobe" "${RUNTIME_ROOT}/"

if [ "${is_darwin}" -eq 1 ]; then
    cp -a "${PREFIX}"/lib/libmpv.*.dylib "${RUNTIME_ROOT}/lib/" 2>/dev/null || true
    # Some installs only produce the unversioned name; normalize to libmpv.2.dylib.
    if [ ! -e "${RUNTIME_ROOT}/lib/libmpv.2.dylib" ]; then
        if [ -e "${PREFIX}/lib/libmpv.dylib" ]; then
            cp -a "${PREFIX}/lib/libmpv.dylib" "${RUNTIME_ROOT}/lib/libmpv.2.dylib"
        fi
    fi
    test -e "${RUNTIME_ROOT}/lib/libmpv.2.dylib"
    copy_darwin_runtime_dependencies "${RUNTIME_ROOT}/lib/libmpv.2.dylib"
else
    cp -a "${PREFIX}"/lib/libmpv.so* "${RUNTIME_ROOT}/lib/"
    test -e "${RUNTIME_ROOT}/lib/libmpv.so.2"
    copy_linux_runtime_dependencies "${RUNTIME_ROOT}/lib/libmpv.so.2"
fi

mkdir -p "${RUNTIME_ROOT}/licenses/mpv" "${RUNTIME_ROOT}/licenses/librempeg"
cp "${MPV_SOURCE}/LICENSE.GPL" "${RUNTIME_ROOT}/licenses/mpv/LICENSE.GPL"
cp "${MPV_SOURCE}/LICENSE.LGPL" "${RUNTIME_ROOT}/licenses/mpv/LICENSE.LGPL"
cp "${LIBREMPEG_SOURCE}/COPYING.AGPLv3" "${RUNTIME_ROOT}/licenses/librempeg/COPYING.AGPLv3"
cp "${LIBREMPEG_SOURCE}/COPYING.GPLv3" "${RUNTIME_ROOT}/licenses/librempeg/COPYING.GPLv3"
cp "${LIBREMPEG_SOURCE}/LICENSE.md" "${RUNTIME_ROOT}/licenses/librempeg/LICENSE.md"
cp "${ROOT}/NOTICE.md" "${RUNTIME_ROOT}/NOTICE.md"

cat > "${RUNTIME_ROOT}/runtime.json" <<EOF
{
  "schemaVersion": 1,
  "name": "mpv-libre-runtime",
  "version": "mpv-${MPV_COMMIT:0:10}.librempeg-${LIBREMPEG_COMMIT:0:10}",
  "engine": "libmpv",
  "mediaBackend": "librempeg",
  "license": "AGPL-3.0-or-later",
  "decoders": ["ac4"],
  "platform": "${RUNTIME_TARGET}",
  "buildProfile": "${BUILD_PROFILE}",
  "sourceCommits": {
    "mpv": "${MPV_COMMIT}",
    "librempeg": "${LIBREMPEG_COMMIT}",
    "libplacebo": "${LIBPLACEBO_COMMIT}"
  }
}
EOF

log "Smoke-testing packaged runtime"
"${RUNTIME_ROOT}/ffmpeg" -hide_banner -decoders 2>&1 |
    grep -E '[[:space:]]ac4[[:space:]]' >/dev/null
if [ "${is_darwin}" -eq 1 ]; then
    smoke_dlopen_libmpv "${RUNTIME_ROOT}/lib/libmpv.2.dylib"
else
    smoke_dlopen_libmpv "${RUNTIME_ROOT}/lib/libmpv.so.2"
fi

TAR=tar
if command -v gtar >/dev/null 2>&1; then
    TAR=gtar
fi
rm -f "${ARTIFACT_ROOT}/${RUNTIME_ARTIFACT}"
"${TAR}" --sort=name --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -C "${RUNTIME_ROOT}" -cJf "${ARTIFACT_ROOT}/${RUNTIME_ARTIFACT}" .
log "Wrote ${ARTIFACT_ROOT}/${RUNTIME_ARTIFACT}"
