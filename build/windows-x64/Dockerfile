FROM alpine:3.22

RUN apk add --no-cache 7zip autoconf automake bash ccache clang cmake coreutils \
        curl diffutils g++ gawk gcc gettext-dev git gperf libtool lld llvm \
        llvm-linker-tools make meson musl-dev nasm patch pkgconf po4a py3-pip \
        py3-jinja2 py3-mako samurai tar texinfo util-linux-misc xz yasm \
    && python3 -m pip install --break-system-packages --no-cache-dir meson==1.11.2 \
    && git config --global http.version HTTP/1.1 \
    && git config --global user.email "mpv-libre-runtime@example.invalid" \
    && git config --global user.name "MpvLibre Runtime build" \
    && mkdir -p /ccache /build/ccache \
    && printf '%s\n' \
        'max_size = 2.0G' \
        'compression = true' \
        'compiler_check = content' \
        'hash_dir = false' \
        > /etc/ccache.conf

ENV CCACHE_DIR=/ccache \
    CCACHE_CONFIGPATH=/etc/ccache.conf \
    PATH="/usr/lib/ccache/bin:${PATH}"

LABEL org.opencontainers.image.source="https://github.com/Zencok/mpv-libre-runtime" \
      org.opencontainers.image.description="MpvLibre Runtime Windows cross-build tools (Alpine)"
