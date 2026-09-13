# CrossMux build image for the NAS build machine.
#
# The toolchain is pinned to the same versions the hosted CI uses
# (.github/workflows/ci.yml) so an artifact produced here is interchangeable
# with the CI artifact:
#   - Python 3.14        (actions/setup-python)
#   - pioarduino 6.1.19  (the PlatformIO Core fork CI installs)
#   - cmake/ninja/libcurl/libssl for the host unit tests in test/
#
# The ESP32 platform, the C3/S3 toolchains and the project lib_deps are NOT
# baked in. They live in the mounted PlatformIO core dir
# (PLATFORMIO_CORE_DIR=/pio-cache) so they survive container replacement and
# rebuild only after a platformio.ini change. The first build downloads them.
#
# Build:
#   sudo docker build -t crossmux-build:1.5.8 docker/nas-build
#
# Do not add the simulator env to this image: it needs SDL2 and a display.

FROM python:3.14-slim-bookworm

ARG PIOARDUINO_VERSION=6.1.19

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_RETRIES=10 \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8 \
    PLATFORMIO_CORE_DIR=/pio-cache

# git          - clone + submodule fetch for freeink-sdk
# build-essential/pkg-config - native bits pulled in by the unit tests
# cmake/ninja  - test/CMakeLists.txt
# libcurl/libssl - test/ link dependencies (as in the CI unit-tests job)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        wget \
        unzip \
        xz-utils \
        bzip2 \
        build-essential \
        pkg-config \
        cmake \
        ninja-build \
        libcurl4-openssl-dev \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install "pioarduino==${PIOARDUINO_VERSION}" \
    && pio --version \
    && git config --global --add safe.directory '*'

WORKDIR /work
