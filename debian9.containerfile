FROM debian:stretch

ARG CLANG_VERSION=11

RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo "deb http://archive.debian.org/debian stretch main" > /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security stretch/updates main" >> /etc/apt/sources.list && \
    apt-get update && \
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

# Per-arch staging trees for static-linking MariaDB Connector/C into
# amxmodx's mysqlx module. Stretch packages this differently from
# buster/bullseye/bookworm: the static archive lives in
# `libmariadbclient-dev` (server-side client lib v10.1.48), not the
# tiny `libmariadb-dev` 2.3.2 shim. Headers go to /usr/include/mysql/
# (not /usr/include/mariadb/) and the .a is already named
# libmariadbclient_r.a (no rename needed for amxmodx's expected layout).
#
# debian BTS #880390 / #1006388 — libmariadbclient-dev is also NOT
# Multi-Arch: same on stretch, so apt-install for multiple arches
# fails. Sidestep via `apt download` + `dpkg-deb -x` per-arch trees,
# same pattern as debian10/11.
RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      dpkg --add-architecture i386 && \
      dpkg --add-architecture arm64 && \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends libmariadbclient-dev && \
      mkdir -p /opt/mariadb-static-amd64/include /opt/mariadb-static-amd64/lib && \
      cp -r /usr/include/mysql/. /opt/mariadb-static-amd64/include/ && \
      cp /usr/lib/x86_64-linux-gnu/libmariadbclient_r.a \
         /opt/mariadb-static-amd64/lib/libmysqlclient_r.a && \
      cd /tmp && mkdir -p mariadb-dl && chmod 0777 mariadb-dl && cd mariadb-dl && \
      apt-get download libmariadbclient-dev:i386 libmariadbclient-dev:arm64 && \
      for arch in i386 arm64; do \
        case $arch in \
          i386)  triplet=i386-linux-gnu;    target=i386 ;; \
          arm64) triplet=aarch64-linux-gnu; target=aarch64 ;; \
        esac && \
        ext=/tmp/mariadb-ext-$arch && \
        out=/opt/mariadb-static-$target && \
        mkdir -p "$ext" "$out/include" "$out/lib" && \
        dpkg-deb -x libmariadbclient-dev_*_$arch.deb "$ext" && \
        cp -r "$ext/usr/include/mysql/." "$out/include/" && \
        cp "$ext/usr/lib/$triplet/libmariadbclient_r.a" "$out/lib/libmysqlclient_r.a"; \
      done && \
      rm -rf /tmp/mariadb-dl /tmp/mariadb-ext-i386 /tmp/mariadb-ext-arm64; \
    elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
      apt-get -o Acquire::Check-Valid-Until=false update && \
      apt-get install -y --no-install-recommends libmariadbclient-dev && \
      mkdir -p /opt/mariadb-static-aarch64/include /opt/mariadb-static-aarch64/lib && \
      cp -r /usr/include/mysql/. /opt/mariadb-static-aarch64/include/ && \
      cp /usr/lib/aarch64-linux-gnu/libmariadbclient_r.a \
         /opt/mariadb-static-aarch64/lib/libmysqlclient_r.a; \
    fi

CMD ["/bin/bash"]