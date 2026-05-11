FROM debian:bullseye AS dump_syms_builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates build-essential git && \
    rm -rf /var/lib/apt/lists/*

ARG DUMP_SYMS_VERSION=2.3.7
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
RUN cargo install --git https://github.com/mozilla/dump_syms --tag v${DUMP_SYMS_VERSION} --locked

FROM debian:bullseye

ARG CLANG_VERSION=14

# Upstream layer (verbatim from alliedmodders/build-containers): standard
# toolset plus clang from apt.llvm.org.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y apt-transport-https lsb-release wget software-properties-common gnupg \
        curl git jq python python3-pip && \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get install -y gcc-multilib g++-multilib lib32z1-dev; \
    fi && \
    wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh ${CLANG_VERSION} && \
    rm llvm.sh

RUN pip3 install git+https://github.com/alliedmodders/ambuild.git

COPY --from=dump_syms_builder /root/.cargo/bin/dump_syms /usr/local/bin/dump_syms

ENV CC=clang-${CLANG_VERSION}
ENV CXX=clang++-${CLANG_VERSION}

# ============================================================================
# goldsrc-net additions: cmake, rsync, nasm (not in upstream's debian11),
# full i386 multilib, aarch64 cross-toolchain + arm64 runtime sysroot (for
# AMBuild's compiler-probe via qemu-user), and libmariadb-dev (+ per-arch
# runtime) for amxmodx's mysqlx module. Net-additive — nothing above this
# line was removed.
# ============================================================================

# Additional native-host tooling: cmake (ReHLDS/Metamod-R/halflife-updated
# cmake builds), rsync (buildchain Makefile + workflows), nasm (amxmodx
# i386 JIT path — debian11 upstream image omits this), and full i386
# multilib (libc6-dev-i386 + linux-libc-dev:i386).
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      dpkg --add-architecture i386 && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        cmake rsync nasm \
        libc6-dev libc6-dev-i386 linux-libc-dev:i386; \
    fi

# aarch64 cross-toolchain + arm64 multi-arch runtime sysroot. AMBuild's
# DetectCxx compiles a probe binary then *executes* it (binfmt_misc +
# qemu-user-static routes aarch64 ELFs through qemu); qemu then needs
# /lib/ld-linux-aarch64.so.1 + libc6 to actually load. Without the sysroot
# the probe fails. Skipped on arm64 hosts where the native compiler is
# already aarch64.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      dpkg --add-architecture arm64 && \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        libc6:arm64 libstdc++6:arm64; \
    fi

# Unversioned aliases for the cross-toolchain so CMake toolchain files
# that probe for `EXISTS /usr/bin/aarch64-linux-gnu-gcc` pick them up
# automatically. debian:bullseye ships the unversioned binaries already,
# so this is typically a no-op there — kept for symmetry with debian10.
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      for v in aarch64-linux-gnu-gcc-10 aarch64-linux-gnu-g++-10; do \
        unv="$(echo $v | sed 's/-10$//')"; \
        [ -e /usr/bin/$unv ] || ln -s /usr/bin/$v /usr/bin/$unv; \
      done; \
    fi

# MariaDB Connector/C — used by amxmodx's mysqlx module. Debian's
# libmariadb-dev ships headers in a single non-multiarch path, so only
# install the dev package for the host arch (amd64) — that gives the
# headers + the amd64 static lib. For i386 / arm64, install the
# runtime-only libmariadb3:<arch> packages so cross-builds link
# dynamically. Deploy hosts already have libmariadb3 installed by any
# MariaDB/MySQL setup.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get update && \
      apt-get install -y --no-install-recommends \
        libmariadb-dev \
        libmariadb3:i386 libmariadb3:arm64; \
    fi

CMD ["/bin/bash"]
