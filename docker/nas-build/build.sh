#!/bin/bash
#
# CrossMux build runner for the Synology NAS build machine.
#
# Runs on the DSM host. It only needs the Docker CLI; git and PlatformIO live
# inside the image, so the NAS itself stays clean. The build root stays inside
# your home directory, so this script never needs root for files - only the
# docker calls do.
#
# Host layout (all under BASE):
#   src/    git checkout that is compiled (created and owned by the container)
#   dist/   collected firmware images, one directory per commit
#   cache/  persistent PlatformIO core dir: platforms, toolchains, lib_deps
#   logs/   full pio output per run
#   image/  fallback Dockerfile context used before src/ exists
#
# Usage:
#   ./build.sh                                  # build the default env at origin/$BRANCH
#   ./build.sh metalio_eink4                    # one env
#   ./build.sh default x4pro metalio_eink4      # several envs, one invocation
#   ./build.sh --rebuild-image default          # rebuild the image first
#   ./build.sh --shell                          # interactive shell in src/, for debugging
#
# Variables:
#   BASE          host build root          (default $HOME/crossmux-build)
#   REPO          git remote to build      (default https://github.com/louenjoy/crossmux.git)
#   BRANCH        branch to clone          (default main)
#   REF           ref to check out         (default $BRANCH; use a tag/sha for a release)
#   IMAGE         image tag                (default crossmux-build:1.5.8)
#   DEFAULT_ENVS  envs when none given     (default default)
#   SKIP_FETCH=1  build the existing src/ as-is, without touching the network
#   JOBS          parallel compile jobs    (default: the NAS CPU count)
#   DOCKER        docker command           (default "sudo -n /usr/local/bin/docker")
#
# Notes:
#   - Envs carrying nightly/rc in the name need CROSSPOINT_RC_HASH; it is
#     derived from the checked-out commit automatically.
#   - The simulator envs are not supported here (no SDL2 or display on the NAS).
#   - To build uncommitted work, push it first, or upload a tree into src/ and
#     run with SKIP_FETCH=1.

set -euo pipefail

BASE="${BASE:-$HOME/crossmux-build}"
REPO="${REPO:-https://github.com/louenjoy/crossmux.git}"
BRANCH="${BRANCH:-main}"
REF="${REF:-$BRANCH}"
IMAGE="${IMAGE:-crossmux-build:1.5.8}"
DEFAULT_ENVS="${DEFAULT_ENVS:-default}"
DOCKER="${DOCKER:-sudo -n /usr/local/bin/docker}"
# Parallel compile jobs. PlatformIO would default to the CPU count anyway; making
# it explicit puts the number in the run log and leaves a knob for this NAS, which
# also runs Jellyfin and qBittorrent - its idle load is already ~4 on 4 cores.
# Lower it to keep the media services responsive; the build gets slower either
# way, so the only real question is who wins the contention.
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
# Optional HTTP proxy for the container, e.g. http://192.168.3.55:7890.
# GitHub connections from this NAS stall intermittently, which PlatformIO
# reports as a download or fetch timeout; routing through the local proxy
# fixes it. Persisted settings live in $BASE/build.env (sourced below).
PROXY="${PROXY:-}"
# ESP-IDF installs extra toolchains through idf_tools.py, which by default pulls
# from GitHub Releases and unpacks into ~/.espressif. Both defaults are wrong
# here: GitHub Releases runs at ~80KB/s from this network (a 177MB xtensa
# toolchain takes ~37 minutes), and the container's HOME is discarded on every
# run, so the toolchain would be re-downloaded each time. Point idf_tools at the
# vendor mirror and keep the tools inside the persistent cache volume.
IDF_GITHUB_ASSETS="${IDF_GITHUB_ASSETS:-dl.espressif.cn/github_assets}"
if [ -f "$BASE/build.env" ]; then
    # shellcheck disable=SC1090
    . "$BASE/build.env"
fi

ACTION="build"
FORCE_IMAGE=0
ENVS=""

usage() {
    cat <<'EOF'
CrossMux NAS build runner.

  build.sh [options] [env ...]

Options:
  --shell           interactive shell inside src/, for debugging
  --rebuild-image   rebuild the docker image before building
  --jobs N          parallel compile jobs (overrides JOBS)
  -h, --help        this text

Variables:
  BASE          host build root          (default $HOME/crossmux-build)
  REPO          git remote to build      (default https://github.com/louenjoy/crossmux.git)
  BRANCH        branch to clone          (default main)
  REF           ref to check out         (default $BRANCH)
  IMAGE         image tag                (default crossmux-build:1.5.8)
  DEFAULT_ENVS  envs when none given     (default default)
  SKIP_FETCH=1  build the existing src/ as-is, without touching the network
  JOBS          parallel compile jobs    (default: CPU count)
  DOCKER        docker command           (default "sudo -n /usr/local/bin/docker")

Examples:
  ./build.sh
  ./build.sh metalio_eink4
  ./build.sh default x4pro gh_release
  REF=v1.5.8 ./build.sh gh_release
  ./build.sh --jobs 2 metalio_eink4
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
    --shell)
        ACTION="shell"
        ;;
    --rebuild-image)
        FORCE_IMAGE=1
        ;;
    --jobs)
        if [ $# -lt 2 ]; then
            echo "build.sh: --jobs needs a value" >&2
            exit 2
        fi
        JOBS="$2"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "build.sh: unknown option '$1'" >&2
        usage >&2
        exit 2
        ;;
    *)
        ENVS="${ENVS:+$ENVS }$1"
        ;;
    esac
    shift
done
ENVS="${ENVS:-$DEFAULT_ENVS}"

say() { printf '\n== %s\n' "$*"; }

proxy_args=()
if [ -n "$PROXY" ]; then
    proxy_args=(
        -e "HTTP_PROXY=$PROXY" -e "HTTPS_PROXY=$PROXY"
        -e "http_proxy=$PROXY" -e "https_proxy=$PROXY"
        -e "NO_PROXY=localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8"
    )
fi

# Runs one container with the build root mounted. $DOCKER is intentionally
# unquoted so a "sudo -n /path/docker" value splits into arguments.
drun() {
    $DOCKER run -i --rm \
        -v "$BASE/src:/work" \
        -v "$BASE/cache:/pio-cache" \
        -v "$BASE/dist:/dist" \
        -v "$BASE/logs:/logs" \
        -w /work \
        -e PLATFORMIO_CORE_DIR=/pio-cache \
        -e HOME=/root \
        -e "IDF_TOOLS_PATH=/pio-cache/idf-tools" \
        -e "IDF_GITHUB_ASSETS=$IDF_GITHUB_ASSETS" \
        ${proxy_args[@]+"${proxy_args[@]}"} \
        "$@"
}

mkdir -p "$BASE/src" "$BASE/dist" "$BASE/cache" "$BASE/logs" "$BASE/image"

# --- image ----------------------------------------------------------------
if [ "$FORCE_IMAGE" = "1" ] || ! $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
    CTX="$BASE/src/docker/nas-build"
    [ -f "$CTX/Dockerfile" ] || CTX="$BASE/image"
    if [ ! -f "$CTX/Dockerfile" ]; then
        echo "build.sh: no Dockerfile in $BASE/src/docker/nas-build or $BASE/image" >&2
        exit 2
    fi
    say "building image $IMAGE from $CTX"
    $DOCKER build -t "$IMAGE" "$CTX"
fi

# --- checkout -------------------------------------------------------------
if [ ! -d "$BASE/src/.git" ]; then
    say "cloning $REPO ($BRANCH) into $BASE/src"
    drun "$IMAGE" git clone --recursive --branch "$BRANCH" "$REPO" .
fi

if [ "${SKIP_FETCH:-0}" != "1" ]; then
    say "checking out $REF"
    drun "$IMAGE" sh -ec "
        git fetch --prune --tags origin
        # Prefer the just-fetched remote ref. Checking out a local branch by
        # name would silently build a stale commit whenever that branch lags
        # behind origin - exactly the case for a branch that was just pushed.
        if git rev-parse --verify --quiet 'origin/$REF' >/dev/null; then
            git checkout -f --detach 'origin/$REF'
        else
            git checkout -f --detach '$REF'
        fi
        git submodule update --init --recursive
    "
fi

HASH="$(drun "$IMAGE" git rev-parse --short=7 HEAD)"
SUBJECT="$(drun "$IMAGE" git log -1 --format=%s)"
say "HEAD $HASH  $SUBJECT"

if [ "$ACTION" = "shell" ]; then
    say "interactive shell, exit to return"
    $DOCKER run -it --rm \
        -v "$BASE/src:/work" -v "$BASE/cache:/pio-cache" -v "$BASE/dist:/dist" \
        -w /work -e PLATFORMIO_CORE_DIR=/pio-cache -e HOME=/root \
        -e "IDF_TOOLS_PATH=/pio-cache/idf-tools" \
        -e "IDF_GITHUB_ASSETS=$IDF_GITHUB_ASSETS" \
        "${proxy_args[@]+"${proxy_args[@]}"}" \
        "$IMAGE" bash
    exit 0
fi

# --- build ----------------------------------------------------------------
pio_envs=""
for env_name in $ENVS; do
    pio_envs="$pio_envs -e $env_name"
done
case "$JOBS" in
*[!0-9]* | '')
    echo "build.sh: JOBS must be a positive integer (got '$JOBS')" >&2
    exit 2
    ;;
esac
pio_jobs="-j $JOBS"

LOG="$BASE/logs/build-$HASH-$(date +%Y%m%d-%H%M%S).log"
say "pio run$pio_envs -j $JOBS   (log: $LOG)"
set +e
drun -e "CROSSPOINT_RC_HASH=$HASH" "$IMAGE" sh -c "pio run $pio_envs $pio_jobs" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" != "0" ]; then
    echo "build.sh: pio run failed (exit $STATUS), log kept at $LOG" >&2
    exit "$STATUS"
fi

# --- collect --------------------------------------------------------------
# .pio/build belongs to the container's root and is not reliably readable from
# the DSM host (ACLs on /volume2/homes), so the copy runs in a container too.
DEST="$BASE/dist/$HASH"
mkdir -p "$DEST"
env_list="$ENVS"
drun "$IMAGE" sh -ec "
    mkdir -p /dist/$HASH
    for env_name in $env_list; do
        for artifact in firmware.bin bootloader.bin partitions.bin firmware.elf; do
            if [ -f /work/.pio/build/\$env_name/\$artifact ]; then
                cp /work/.pio/build/\$env_name/\$artifact /dist/$HASH/\$env_name-\$artifact
            fi
        done
    done
    chmod 644 /dist/$HASH/* 2>/dev/null || true
    cd /dist/$HASH && rm -f SHA256SUMS && sha256sum ./* > SHA256SUMS
"
collected="$(ls -1 "$DEST" | grep -c 'firmware\.bin$' || true)"
if [ "$collected" = "0" ]; then
    echo "build.sh: build succeeded but no firmware artifacts were found" >&2
    exit 3
fi

say "artifacts in $DEST"
ls -1 "$DEST"
grep -E '^Processing |^RAM:|^Flash:' "$LOG" || true
