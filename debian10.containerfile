FROM debian:buster

ARG CLANG_VERSION=11

# Upstream layer (from alliedmodders/build-containers): pin the EOL
# repos at archive.debian.org, install the standard toolset, then
# install clang via apt.llvm.org's installer.
#
# The amd64-only packages (gcc-multilib / g++-multilib / lib32z1-dev)
# are gated on $(dpkg --print-architecture) so this image can also
# be built for linux/arm64 — those packages have no arm64 candidate
# on debian:buster and would fail apt-get install otherwise.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo "deb http://archive.debian.org/debian buster main" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security buster/updates main" >> /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get upgrade -y && \
    apt-get install -y apt-transport-https lsb-release wget software-properties-common gnupg \
        curl git jq nasm python python3-pip && \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get install -y gcc-multilib g++-multilib lib32z1-dev; \
    fi && \
    wget https://apt.llvm.org/llvm.sh && \
    chmod +x llvm.sh && \
    ./llvm.sh ${CLANG_VERSION} && \
    rm llvm.sh

RUN pip3 install git+https://github.com/alliedmodders/ambuild.git

ENV CC=clang-${CLANG_VERSION}
ENV CXX=clang++-${CLANG_VERSION}

# ============================================================================
# goldsrc-net additions: cmake, rsync, full i386 multilib, aarch64 cross-
# toolchain + arm64 runtime sysroot (for AMBuild's compiler-probe via
# qemu-user), and libmariadb-dev (+ per-arch runtime) for amxmodx's mysqlx
# module. Net-additive — nothing above this line was removed.
# ============================================================================

# Additional native-host tooling needed by ReHLDS / Metamod-R / halflife-updated
# (cmake) and the buildchain Makefile (rsync), plus full i386 multilib
# (libc6-dev-i386 supplies /usr/include/i386-linux-gnu/asm/* which `cc -m32`
# requires; linux-libc-dev:i386 supplies the kernel headers).
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      dpkg --add-architecture i386 && \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends \
        cmake rsync \
        libc6-dev libc6-dev-i386 linux-libc-dev:i386; \
    fi

# aarch64 cross-toolchain + arm64 multi-arch runtime sysroot. The sysroot
# is the load-bearing piece: AMBuild's DetectCxx compiles a probe binary
# and *executes* it. binfmt_misc + qemu-user-static routes the aarch64 ELF
# through qemu, which then needs /lib/ld-linux-aarch64.so.1 + libc6 to
# actually load. Without the sysroot the probe fails and AMBuild reports
# "Unable to find a suitable CC compiler". Skipped on arm64 hosts.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      dpkg --add-architecture arm64 && \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        libc6-dev-arm64-cross \
        libc6:arm64 libstdc++6:arm64; \
    fi

# Unversioned aliases for the cross-toolchain so CMake toolchain files that
# probe for `EXISTS /usr/bin/aarch64-linux-gnu-gcc` (e.g. halflife-updated's
# cmake/LinuxToolchain-aarch64.cmake, ReHLDS's cmake/aarch64-linux-gnu.toolchain.cmake)
# pick them up automatically. debian:buster only ships the versioned
# binaries; create the unversioned symlinks.
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      for v in aarch64-linux-gnu-gcc-8 aarch64-linux-gnu-g++-8; do \
        unv="$(echo $v | sed 's/-8$//')"; \
        [ -e /usr/bin/$unv ] || ln -s /usr/bin/$v /usr/bin/$unv; \
      done; \
    fi

# MariaDB Connector/C — used by amxmodx's mysqlx module. Debian's
# libmariadb-dev ships headers in a single non-multiarch path, so on
# amd64 we install dev + the i386/arm64 runtime libs (for cross-link).
# On a native arm64 image, just install the dev package — there's no
# multi-arch cross going on, and the native arm64 dev gives the same
# headers + the arm64 static lib. Deploy hosts already have libmariadb3
# installed by any MariaDB/MySQL setup.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends \
        libmariadb-dev \
        libmariadb3:i386 libmariadb3:arm64; \
    elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends libmariadb-dev; \
    fi

# Per-arch staging trees for static-linking MariaDB Connector/C into
# amxmodx's mysqlx module. libmariadb-dev is NOT Multi-Arch: same in
# any Debian release (debian BTS #880390, #1006388 — long-standing
# upstream bug across stretch/buster/bullseye/bookworm), so we can't
# apt-install dev packages for multiple arches concurrently. Sidestep
# via `apt download` + `dpkg-deb -x` into per-arch trees.
#
# Each /opt/mariadb-static-<arch>/ has the shape amxmodx's
# mysqlx/AMBuilder expects with --mysql=<path>:
#   <path>/include/mysql.h, ma_io.h, server/*.h, etc.
#   <path>/lib/libmysqlclient_r.a   (renamed from libmariadbclient.a)
# so the same self-contained static-link pattern upstream uses with
# Oracle's bundled libmysqlclient_r.a works here with Connector/C 3.x.
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      mkdir -p /opt/mariadb-static-amd64/include /opt/mariadb-static-amd64/lib && \
      cp -r /usr/include/mariadb/. /opt/mariadb-static-amd64/include/ && \
      cp /usr/lib/x86_64-linux-gnu/libmariadbclient.a \
         /opt/mariadb-static-amd64/lib/libmysqlclient_r.a && \
      cd /tmp && mkdir -p mariadb-dl && chmod 0777 mariadb-dl && cd mariadb-dl && \
      apt-get download libmariadb-dev:i386 libmariadb-dev:arm64 && \
      for arch in i386 arm64; do \
        case $arch in \
          i386)  triplet=i386-linux-gnu;    target=i386 ;; \
          arm64) triplet=aarch64-linux-gnu; target=aarch64 ;; \
        esac && \
        ext=/tmp/mariadb-ext-$arch && \
        out=/opt/mariadb-static-$target && \
        mkdir -p "$ext" "$out/include" "$out/lib" && \
        dpkg-deb -x libmariadb-dev_*_$arch.deb "$ext" && \
        cp -r "$ext/usr/include/mariadb/." "$out/include/" && \
        cp "$ext/usr/lib/$triplet/libmariadbclient.a" "$out/lib/libmysqlclient_r.a"; \
      done && \
      rm -rf /tmp/mariadb-dl /tmp/mariadb-ext-i386 /tmp/mariadb-ext-arm64; \
    elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
      mkdir -p /opt/mariadb-static-aarch64/include /opt/mariadb-static-aarch64/lib && \
      cp -r /usr/include/mariadb/. /opt/mariadb-static-aarch64/include/ && \
      cp /usr/lib/aarch64-linux-gnu/libmariadbclient.a \
         /opt/mariadb-static-aarch64/lib/libmysqlclient_r.a; \
    fi

# ============================================================================
# goldsrc-net: final build tooling so build-containers is THE image consumers
# pull directly (mod-ts CI, the buildchain orchestrator, other repos) — no
# separately-published derived image.
#   * cmake 3.29 — AsmJit (Metamod-R/amxmodx) and modern CMakeLists need >=3.24;
#     buster's apt cmake is 3.13.4. Installed to /usr/local (shadows apt cmake).
#     Arch-aware: this image is built multi-arch (amd64 + arm64).
#   * file / binutils / pkg-config / python3-venv — misc native build utils.
#   * ambuild-python wrapper so Makefile recipes can invoke it by name.
# QUIC (Rust/quiche + libcurl) is deliberately NOT here: it stays a buildchain
# `quic` local layer for manual QUIC builds. Published 64-bit images stay QUIC-free.
# ============================================================================
RUN CMAKE_VERSION=3.29.6; \
    case "$(dpkg --print-architecture)" in \
      amd64) CMAKE_ARCH=x86_64 ;; \
      arm64) CMAKE_ARCH=aarch64 ;; \
      *)     CMAKE_ARCH=x86_64 ;; \
    esac; \
    curl -sSL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${CMAKE_ARCH}.tar.gz" \
    | tar -xz -C /usr/local --strip-components=1

RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends file binutils pkg-config python3-venv

RUN printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' > /usr/local/bin/ambuild-python \
 && chmod +x /usr/local/bin/ambuild-python

CMD ["/bin/bash"]
