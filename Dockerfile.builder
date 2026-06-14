FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Pacific/Auckland

RUN apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y \
      git curl wget ca-certificates jq \
      build-essential bc kmod cpio rsync xz-utils zstd tar \
      flex bison libncurses-dev \
      libssl-dev \
      libelf-dev libdw-dev elfutils dwarves pahole \
      debhelper devscripts fakeroot \
      clang lld llvm ccache python3 perl gawk gettext \
      libudev-dev libpci-dev lz4 bsdutils \
      file xxd pkg-config \
      rustc cargo cmake make ninja-build protobuf-compiler bpftool \
      zlib1g-dev libzstd-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
