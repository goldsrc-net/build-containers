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

CMD ["/bin/bash"]