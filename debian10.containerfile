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

CMD ["/bin/bash"]
