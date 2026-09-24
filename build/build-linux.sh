#!/usr/bin/env bash
# Build (and optionally verify) a Linux flavour inside its build container.
#
# The Linux builds cannot use a job-level `container:` in GitHub Actions. The
# runner injects its own Node to execute JavaScript actions such as
# actions/checkout, and that binary needs glibc 2.28 -- which manylinux2014
# (CentOS 7, glibc 2.17) does not have and Alpine does not provide at all. So
# the job runs on the host and only the build is containerised, which is also
# exactly how it runs locally: CI and a developer machine exercise one path.
#
# The container is always the *native* architecture; there is no emulation
# here. aarch64 artifacts come from running this on an arm64 host.
#
# Usage: build-linux.sh --platform <arch>-linux-<gnu|musl|musl-static>
#                       [--perl-version 5.44.0] [--image IMAGE]
#                       [--out-dir dist] [--jobs N] [--run-tests]
#                       [--verify] [--verify-only]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/build/common.sh"

PLATFORM=""
PERL_VERSION=""
IMAGE=""
OUT_DIR="dist"
JOBS=""
RUN_TESTS=0
VERIFY=0
BUILD=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --perl-version) PERL_VERSION="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --run-tests) RUN_TESTS=1; shift ;;
        --verify) VERIFY=1; shift ;;
        --verify-only) VERIFY=1; BUILD=0; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "${PLATFORM}" ]] || die "--platform is required"
[[ -n "${PERL_VERSION}" ]] || PERL_VERSION="$(json_get "${REPO_ROOT}/versions.json" default)"
command -v docker >/dev/null 2>&1 || die "docker is required to build the Linux flavours"

# manylinux2014 pins the glibc builds to 2.17, so the artifact runs on anything
# from RHEL 7 onward. The musl flavours build on Alpine, which is the only
# mainstream musl userland.
arch="${PLATFORM%%-*}"
case "${PLATFORM}" in
    x86_64-linux-gnu|aarch64-linux-gnu)
        DEFAULT_IMAGE="quay.io/pypa/manylinux2014_${arch}"
        SETUP=":"
        ;;
    x86_64-linux-musl|aarch64-linux-musl|x86_64-linux-musl-static|aarch64-linux-musl-static)
        DEFAULT_IMAGE="alpine:3.20"
        # build-base brings gcc, make and musl-dev (so libc.a, which the static
        # flavour links against) plus binutils for strip/objdump/readelf. GNU
        # tar is requested explicitly: busybox tar has no --owner/
        # --numeric-owner/--format, which deterministic packaging relies on.
        #
        # tzdata is only there for the test suite. ext/POSIX/t/time.t checks
        # DST transitions under TZ=Europe/Paris; with no zoneinfo, musl quietly
        # falls back to UTC, the test switches to a bare POSIX "PST8PDT" string,
        # and musl's built-in default DST rule disagrees with the expected
        # instants. The artifact itself is unaffected -- it reads whatever
        # zoneinfo the target machine has.
        SETUP="apk add --no-cache bash python3 build-base curl xz tar file tzdata >/dev/null"
        ;;
    *) die "not a Linux platform: ${PLATFORM}" ;;
esac
[[ -n "${IMAGE}" ]] || IMAGE="${DEFAULT_IMAGE}"

# The repository is bind-mounted at /work, so the archive lands straight in the
# caller's --out-dir on the host.
build_args=(
    --platform "${PLATFORM}"
    --perl-version "${PERL_VERSION}"
    --out-dir "/work/${OUT_DIR}"
)
[[ -n "${JOBS}" ]] && build_args+=( --jobs "${JOBS}" )
(( RUN_TESTS )) && build_args+=( --run-tests )

verify_archive=""
if (( VERIFY )); then
    verify_archive="/work/${OUT_DIR}/perl-${PERL_VERSION}-${PLATFORM}.tar.xz"
fi

inner="
set -eu
${SETUP}

# Whatever happens, hand the output tree back to the invoking user rather than
# leaving root-owned files in their checkout.
trap 'chown -R \"\${OWNER}\" \"\${OUT}\" 2>/dev/null || true' EXIT

if [ -n \"\${DO_BUILD}\" ]; then
    bash /work/build/build-unix.sh \"\$@\"
fi

if [ -n \"\${VERIFY_ARCHIVE}\" ]; then
    bash /work/build/verify-unix.sh \\
        --archive \"\${VERIFY_ARCHIVE}\" --perl-version \"\${PERL_VERSION}\"
fi
"

if (( BUILD )); then
    log "Building ${PLATFORM} in ${IMAGE}"
else
    log "Verifying ${PLATFORM} in ${IMAGE}"
fi

docker run --rm \
    --volume "${REPO_ROOT}:/work" \
    --workdir /work \
    --env "OWNER=$(id -u):$(id -g)" \
    --env "OUT=/work/${OUT_DIR}" \
    --env "DO_BUILD=$( ((BUILD)) && echo 1 )" \
    --env "PERL_VERSION=${PERL_VERSION}" \
    --env "VERIFY_ARCHIVE=${verify_archive}" \
    "${IMAGE}" \
    sh -euc "${inner}" _ "${build_args[@]}"

log "Finished ${PLATFORM}"
