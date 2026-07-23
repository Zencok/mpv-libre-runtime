#!/usr/bin/env bash
# Verify a packaged Unix runtime: archive layout, AC-4 decode, libmpv client API.
set -euo pipefail

RUNTIME_DIRECTORY=${1:?Runtime directory is required}
FIXTURE_PATH=${2:?Fixture path is required}
RUNTIME_DIRECTORY=$(cd "${RUNTIME_DIRECTORY}" && pwd)
FIXTURE_PATH=$(cd "$(dirname "${FIXTURE_PATH}")" && pwd)/$(basename "${FIXTURE_PATH}")

log() {
    printf 'verify: %s\n' "$*"
}

fail() {
    printf 'verify failed: %s\n' "$*" >&2
    exit 1
}

test -s "${RUNTIME_DIRECTORY}/ffmpeg" || fail "ffmpeg missing"
test -s "${RUNTIME_DIRECTORY}/ffprobe" || fail "ffprobe missing"
test -s "${RUNTIME_DIRECTORY}/runtime.json" || fail "runtime.json missing"
test -s "${RUNTIME_DIRECTORY}/NOTICE.md" || fail "NOTICE.md missing"
test -s "${RUNTIME_DIRECTORY}/licenses/librempeg/COPYING.AGPLv3" || fail "AGPL license missing"
test -s "${RUNTIME_DIRECTORY}/licenses/mpv/LICENSE.GPL" || fail "mpv GPL license missing"
test -s "${RUNTIME_DIRECTORY}/licenses/mpv/LICENSE.LGPL" || fail "mpv LGPL license missing"

if [ "$(uname -s)" = "Darwin" ]; then
    LIBRARY_PATH="${RUNTIME_DIRECTORY}/lib/libmpv.2.dylib"
    DL_FLAG=""
    export DYLD_LIBRARY_PATH="${RUNTIME_DIRECTORY}/lib${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
else
    LIBRARY_PATH="${RUNTIME_DIRECTORY}/lib/libmpv.so.2"
    DL_FLAG="-ldl"
    export LD_LIBRARY_PATH="${RUNTIME_DIRECTORY}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    test -e "${RUNTIME_DIRECTORY}/lib/libstdc++.so.6" || fail "libstdc++.so.6 was not packaged"
    test -e "${RUNTIME_DIRECTORY}/lib/libgcc_s.so.1" || fail "libgcc_s.so.1 was not packaged"
fi
test -s "${LIBRARY_PATH}" || fail "libmpv missing at ${LIBRARY_PATH}"

for forbidden in include libmpv.a libmpv.dll.a; do
    if [ -e "${RUNTIME_DIRECTORY}/${forbidden}" ]; then
        fail "runtime contains forbidden SDK entry: ${forbidden}"
    fi
done

log "checking LibreMPEG AC-4 decoder list"
"${RUNTIME_DIRECTORY}/ffmpeg" -hide_banner -decoders 2>&1 \
    | grep -E '[[:space:]]ac4[[:space:]]' >/dev/null \
    || fail "AC-4 decoder missing from ffmpeg -decoders"

log "decoding AC-4 fixture"
"${RUNTIME_DIRECTORY}/ffmpeg" -hide_banner -v error \
    -i "${FIXTURE_PATH}" -t 2 -f null - \
    || fail "ffmpeg failed to decode AC-4 fixture"

log "probing libmpv client API"
PROBE_ROOT=$(mktemp -d)
trap 'rm -rf "${PROBE_ROOT}"' EXIT
cat > "${PROBE_ROOT}/probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*create_fn)(void);
typedef int (*set_option_fn)(void *, const char *, const char *);
typedef int (*initialize_fn)(void *);
typedef char *(*get_property_fn)(void *, const char *);
typedef unsigned long (*api_version_fn)(void);
typedef void (*free_fn)(void *);
typedef void (*destroy_fn)(void *);

static void *symbol(void *library, const char *name) {
    void *value = dlsym(library, name);
    if (!value) {
        fprintf(stderr, "Missing symbol %s: %s\n", name, dlerror());
        exit(2);
    }
    return value;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    create_fn create = (create_fn)symbol(library, "mpv_create");
    set_option_fn set_option = (set_option_fn)symbol(library, "mpv_set_option_string");
    initialize_fn initialize = (initialize_fn)symbol(library, "mpv_initialize");
    get_property_fn get_property = (get_property_fn)symbol(library, "mpv_get_property_string");
    api_version_fn api_version = (api_version_fn)symbol(library, "mpv_client_api_version");
    free_fn mpv_free = (free_fn)symbol(library, "mpv_free");
    destroy_fn destroy = (destroy_fn)symbol(library, "mpv_terminate_destroy");
    void *player = create();
    if (!player) {
        fprintf(stderr, "mpv_create returned NULL\n");
        return 3;
    }
    set_option(player, "config", "no");
    set_option(player, "audio", "no");
    set_option(player, "video", "no");
    if (initialize(player) < 0) {
        fprintf(stderr, "mpv_initialize failed\n");
        destroy(player);
        return 4;
    }
    char *decoders = get_property(player, "decoder-list");
    if (!decoders || !strstr(decoders, "\"codec\":\"ac4\"")) {
        fprintf(stderr, "libmpv decoder-list does not contain AC-4\n");
        if (decoders) mpv_free(decoders);
        destroy(player);
        return 5;
    }
    mpv_free(decoders);
    unsigned long version = api_version();
    printf("libmpv client API %lu.%lu; LibreMPEG AC-4 verified.\n",
        (version >> 16) & 0xffff, version & 0xffff);
    destroy(player);
    dlclose(library);
    return 0;
}
EOF

cc -O2 -o "${PROBE_ROOT}/probe" "${PROBE_ROOT}/probe.c" ${DL_FLAG}
if ! "${PROBE_ROOT}/probe" "${LIBRARY_PATH}"; then
    if [ "$(uname -s)" != "Darwin" ]; then
        log "ldd for packaged libmpv:"
        ldd "${LIBRARY_PATH}" || true
    else
        log "otool -L for packaged libmpv:"
        otool -L "${LIBRARY_PATH}" || true
    fi
    fail "libmpv probe failed"
fi

log "ok"
