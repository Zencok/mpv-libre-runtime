#!/bin/sh
set -eu

SOURCE_ROOT=$1
BUILD_ROOT=$2
OUTPUT_PATH=$3
STAGING_ROOT=/build/mpv-libre-runtime-source-bundle

rm -rf "${STAGING_ROOT}"
mkdir -p \
    "${STAGING_ROOT}/sources/mingw-cmake-env" \
    "${STAGING_ROOT}/distribution"

tar --exclude-vcs -C "${SOURCE_ROOT}" -cf - . \
    | tar -x -C "${STAGING_ROOT}/sources/mingw-cmake-env"

for prefix in "${BUILD_ROOT}"/packages/*-prefix; do
    [ -d "${prefix}/src" ] || continue
    package=$(basename "${prefix}" -prefix)
    case "${package}" in
        llvm|mingw*|cmake*|meson*|ninja*|pkgconf*|rust*)
            continue
            ;;
    esac
    source_path=""
    for candidate in "${prefix}/src"/*; do
        [ -d "${candidate}" ] || continue
        case "$(basename "${candidate}")" in
            *-build|*-stamp)
                continue
                ;;
        esac
        source_path="${candidate}"
        break
    done
    [ -n "${source_path}" ] || continue
    destination="${STAGING_ROOT}/sources/${package}"
    mkdir -p "${destination}"
    tar --exclude-vcs -C "${source_path}" -cf - . \
        | tar -x -C "${destination}"
done

cp -a \
    /workspace/.github \
    /workspace/build \
    /workspace/fixtures \
    /workspace/schemas \
    /workspace/scripts \
    "${STAGING_ROOT}/distribution/"
cp \
    /workspace/CONTRIBUTING.md \
    /workspace/LICENSE \
    /workspace/NOTICE.md \
    /workspace/package.json \
    /workspace/README.md \
    /workspace/README.zh-CN.md \
    /workspace/SECURITY.md \
    /workspace/versions.lock.json \
    "${STAGING_ROOT}/distribution/"

rm -f "${OUTPUT_PATH}"
tar --sort=name --mtime='UTC 1970-01-01' \
    --owner=0 --group=0 --numeric-owner \
    -C "${STAGING_ROOT}" -cJf "${OUTPUT_PATH}" .
