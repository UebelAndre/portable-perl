#!/usr/bin/env bash
# Build a relocatable, portable Perl distribution for Linux or macOS.
#
# The resulting tree can be unpacked anywhere and moved afterwards: @INC and
# every path in %Config are resolved at runtime relative to the perl binary.
#
# Usage: build-unix.sh --platform <platform>
#                      [--perl-version 5.44.0] [--out-dir dist] [--jobs N]
#                      [--optimize FLAGS] [--run-tests]
#
# Platforms:
#   {x86_64,aarch64}-linux-gnu           glibc, dynamic, XS-capable
#   {x86_64,aarch64}-linux-musl          musl, dynamic, XS-capable
#   {x86_64,aarch64}-linux-musl-static   musl, fully static, no loadable XS
#   {x86_64,aarch64}-macos               libSystem, XS-capable
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/build/common.sh"

PLATFORM=""
PERL_VERSION=""
OUT_DIR="${REPO_ROOT}/dist"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
RUN_TESTS=0

# Release build only. Deliberately omits -g: debug info roughly triples the
# unstripped tree and embeds build-host paths. Assertions are already compiled
# out, because perl.h defines NDEBUG whenever DEBUGGING is not set.
PERL_OPTIMIZE="${PERL_OPTIMIZE:--O3}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --perl-version) PERL_VERSION="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --optimize) PERL_OPTIMIZE="$2"; shift 2 ;;
        --run-tests) RUN_TESTS=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "${PERL_OPTIMIZE}" in
    *-g*) die "refusing to build with debug info in optimize flags: ${PERL_OPTIMIZE}" ;;
esac

[[ -n "${PLATFORM}" ]] || die "--platform is required"
[[ -n "${PERL_VERSION}" ]] || PERL_VERSION="$(json_get "${REPO_ROOT}/versions.json" default)"

PERL_URL="$(json_get "${REPO_ROOT}/versions.json" perl "${PERL_VERSION}" url)"
PERL_SHA256="$(json_get "${REPO_ROOT}/versions.json" perl "${PERL_VERSION}" sha256)"
[[ -n "${PERL_URL}" ]] || die "perl ${PERL_VERSION} is not listed in versions.json"

DIST_NAME="perl-${PERL_VERSION}-${PLATFORM}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portable-perl.XXXXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# `PREFIX` only ever exists on the build machine. Every reference to it is
# rewritten to a `.../`-relative form during post-processing, and verify-unix.sh
# fails the build if any reference survives.
PREFIX="${WORK}/prefix"

log "Building ${DIST_NAME} (jobs=${JOBS})"

# --- platform configuration -------------------------------------------------

configure_extra=()

case "${PLATFORM}" in
    x86_64-linux-gnu|aarch64-linux-gnu)
        # -Wl,-E (added by Configure on Linux) exports the interpreter's symbols
        # so XS .so files can resolve them at dlopen() time. libperl is static,
        # but dynamic loading stays on.
        #
        # crypt() needs care. manylinux replaces glibc's libcrypt with its own
        # build of libxcrypt in /usr/local/lib, whose SONAME is libcrypt.so.2 --
        # a name essentially no distribution ships (Debian, Ubuntu and Fedora
        # are all still on libcrypt.so.1). Linking it dynamically produces a
        # perl that will not start anywhere but inside the build container, so
        # link the static archive instead: putting it alone in a directory that
        # the linker searches first makes -lcrypt resolve to libcrypt.a, since
        # there is no libcrypt.so beside it. verify-unix.sh rejects a libcrypt
        # DT_NEEDED entry outright, so a silent regression here fails the build.
        if [[ -f /usr/local/lib/libcrypt.a ]]; then
            mkdir -p "${WORK}/static-libs"
            cp /usr/local/lib/libcrypt.a "${WORK}/static-libs/"
            configure_extra+=( -Aprepend:ldflags="-L${WORK}/static-libs " )
        fi
        ;;
    x86_64-linux-musl|aarch64-linux-musl)
        # musl has crypt() in libc, so there is no libcrypt to worry about.
        ;;
    x86_64-linux-musl-static|aarch64-linux-musl-static)
        # A single dependency-free binary. musl's static dlopen is a stub that
        # always fails (src/ldso/dlopen.c), so DynaLoader could not work even if
        # it were left enabled -- -Uusedl instead links every core extension
        # directly into the interpreter. The trade-off, per perl's INSTALL: "you
        # won't be able to use any new extension (XS) module without recompiling
        # perl itself". Core XS still works; perl_xs targets will not.
        configure_extra+=( -Uusedl -Aappend:ldflags=' -static' )
        ;;
    x86_64-macos)
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
        ;;
    aarch64-macos)
        # 11.0 is the first macOS release on Apple silicon.
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
        ;;
    *) die "unsupported platform for build-unix.sh: ${PLATFORM}" ;;
esac

# --- fetch and unpack -------------------------------------------------------

src_tarball="${WORK}/perl-${PERL_VERSION}.tar.gz"
fetch "${PERL_URL}" "${src_tarball}" "${PERL_SHA256}"

log "Unpacking Perl source"
tar xzf "${src_tarball}" -C "${WORK}"
src_dir="${WORK}/perl-${PERL_VERSION}"
[[ -d "${src_dir}" ]] || die "expected source directory ${src_dir}"

# --- configure --------------------------------------------------------------
#
# -Duserelocatableinc  : paths stored as ".../<rel>", resolved against $^X at runtime
# -Uuseshrplib         : mandatory -- Configure rejects a shared libperl together
#                        with userelocatableinc, because a shared libperl needs a
#                        hard-coded rpath. libperl is linked into the binary.
# -Dusedl              : keep DynaLoader, so XS modules (.so/.bundle) still load.
#                        This is what rules_perl's perl_xs rule produces.
# -Dusethreads         : ithreads on, matching Windows (where they are required
#                        to emulate fork) so %Config is uniform across platforms.

log "Running Configure"
(
    cd "${src_dir}"
    ./Configure -des \
        -Dprefix="${PREFIX}" \
        -Duserelocatableinc \
        -Uuseshrplib \
        -Dusedl \
        -Dusethreads \
        -Duse64bitall \
        -Dman1dir=none -Dman3dir=none \
        -Dhtml1dir=none -Dhtml3dir=none \
        -Doptimize="${PERL_OPTIMIZE}" \
        -Dcf_by='portable-perl' \
        -Dcf_email='portable-perl@localhost' \
        -Dperladmin='portable-perl@localhost' \
        -Dmyhostname='portable-perl' \
        "${configure_extra[@]+"${configure_extra[@]}"}"
) || die "Configure failed"

log "Compiling with optimize=${PERL_OPTIMIZE}"
make -C "${src_dir}" -j"${JOBS}" >/dev/null || die "make failed"

if (( RUN_TESTS )); then
    # Worth the ~10 minutes: this is the check that an aggressive optimisation
    # level did not miscompile the interpreter.
    log "Running the Perl test suite"
    make -C "${src_dir}" -j"${JOBS}" test_harness || die "perl test suite failed"
fi

log "Installing to staging prefix"
make -C "${src_dir}" install >/dev/null || die "make install failed"

# --- post-process -----------------------------------------------------------

"${REPO_ROOT}/build/postprocess-unix.sh" \
    --prefix "${PREFIX}" \
    --perl-version "${PERL_VERSION}" \
    --platform "${PLATFORM}" \
    --scrub-dir "${WORK}"

# --- bundle cpanm -----------------------------------------------------------

install_cpanm "${PREFIX}" "${WORK}"

# --- package ----------------------------------------------------------------

mkdir -p "${OUT_DIR}"
staged="${WORK}/${DIST_NAME}"
mv "${PREFIX}" "${staged}"

archive="${OUT_DIR}/${DIST_NAME}.tar.xz"
log "Creating ${archive}"
archive_tree "${WORK}" "${DIST_NAME}" "${archive}"

# shasum(1) is a perl script and is absent from the Alpine builder, so go
# through the same helper the download checks use.
( cd "${OUT_DIR}" \
    && printf '%s  %s\n' "$(sha256_of "${DIST_NAME}.tar.xz")" "${DIST_NAME}.tar.xz" \
       > "${DIST_NAME}.tar.xz.sha256" )

log "Built ${archive} ($(du -h "${archive}" | cut -f1))"
