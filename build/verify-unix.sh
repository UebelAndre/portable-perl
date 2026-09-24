#!/usr/bin/env bash
# Acceptance-test a built distribution archive.
#
# Usage: verify-unix.sh --archive dist/perl-5.44.0-x86_64-linux-gnu.tar.xz
#                       [--perl-version 5.44.0] [--max-glibc 2.17]
#                       [--static | --no-static]
#
# The musl-static flavour is detected from the archive name; --static and
# --no-static override that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/build/common.sh"

ARCHIVE=""
PERL_VERSION=""
MAX_GLIBC="2.17"
STATIC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) ARCHIVE="$2"; shift 2 ;;
        --perl-version) PERL_VERSION="$2"; shift 2 ;;
        --max-glibc) MAX_GLIBC="$2"; shift 2 ;;
        --static) STATIC=1; shift ;;
        --no-static) STATIC=0; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -f "${ARCHIVE}" ]] || die "--archive must point at an existing file"
[[ -n "${PERL_VERSION}" ]] || PERL_VERSION="$(json_get "${REPO_ROOT}/versions.json" default)"

ARCHIVE="$(cd "$(dirname "${ARCHIVE}")" && pwd)/$(basename "${ARCHIVE}")"

# The fully static musl flavour is identified by its filename unless overridden.
if [[ -z "${STATIC}" ]]; then
    case "$(basename "${ARCHIVE}")" in
        *-musl-static.tar.xz) STATIC=1 ;;
        *) STATIC=0 ;;
    esac
fi
DYNALOADER=$(( STATIC ? 0 : 1 ))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portable-perl-verify.XXXXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

failures=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf 'ok   - %s\n' "${desc}"
    else
        printf 'FAIL - %s\n' "${desc}"
        failures=$((failures + 1))
    fi
}

log "Unpacking ${ARCHIVE}"
mkdir -p "${WORK}/a"
tar xJf "${ARCHIVE}" -C "${WORK}/a"
root="$(echo "${WORK}/a"/*)"
perl_bin="${root}/bin/perl"
[[ -x "${perl_bin}" ]] || die "no executable bin/perl in the archive"

# --- 1. build-host path leakage ---------------------------------------------
#
# A distribution that mentions the machine that built it is not hermetic. These
# are the roots the CI runners and containers actually build under.

log "Scanning for build-host paths"
leak_patterns=(
    '/home/runner/work'
    '/Users/runner/work'
    '/private/var/folders'
    '/opt/portable-perl'
    'portable-perl\.[A-Za-z0-9]\{8\}'   # the mktemp -d template
)
for pat in "${leak_patterns[@]}"; do
    hits="$(grep -rIl "${pat}" "${root}" 2>/dev/null || true)"
    if [[ -n "${hits}" ]]; then
        printf 'FAIL - no build-host path matching %s\n' "${pat}"
        # shellcheck disable=SC2086  # deliberate split: one offending file per line
        printf '#   %s\n' ${hits}
        failures=$((failures + 1))
    else
        printf 'ok   - no build-host path matching %s\n' "${pat}"
    fi
done

# --- 2. binary portability ---------------------------------------------------

case "$(uname -s)" in
Linux)
    if (( STATIC )); then
        # The whole point of this flavour: no interpreter, no NEEDED entries,
        # nothing to resolve on the target machine.
        log "Checking that the binary is fully static"
        if command -v objdump >/dev/null 2>&1; then
            needed="$(objdump -p "${perl_bin}" 2>/dev/null | awk '/NEEDED/ {print $2}')"
            if [[ -n "${needed}" ]]; then
                printf 'FAIL - static build has shared dependencies: %s\n' "${needed}"
                failures=$((failures + 1))
            else
                printf 'ok   - no shared library dependencies\n'
            fi
        fi
        if command -v readelf >/dev/null 2>&1; then
            if readelf -l "${perl_bin}" 2>/dev/null | grep -q 'INTERP'; then
                printf 'FAIL - static build still requests a program interpreter\n'
                failures=$((failures + 1))
            else
                printf 'ok   - no PT_INTERP segment\n'
            fi
        fi
        # A static musl perl must not ship loadable extensions: they could never
        # be opened, so their presence would mean -Uusedl did not take effect.
        so_count="$(find "${root}" -name '*.so' -type f | wc -l)"
        check "no loadable XS objects are shipped (found ${so_count})" test "${so_count}" -eq 0

    elif command -v objdump >/dev/null 2>&1; then
        # Versioned glibc symbols only exist on the gnu flavour; on musl this
        # finds nothing and the check is simply skipped.
        log "Checking glibc symbol floor"
        # `|| true`: on musl there are no GLIBC_ symbols at all, and grep's
        # empty-match exit status would otherwise trip pipefail.
        max_seen="$( { objdump -T "${perl_bin}" 2>/dev/null \
            | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
            | sed 's/GLIBC_//' | sort -uV | tail -1; } || true )"
        printf '#   highest glibc symbol required: %s (limit %s)\n' "${max_seen:-none}" "${MAX_GLIBC}"
        if [[ -n "${max_seen}" ]]; then
            highest="$(printf '%s\n%s\n' "${max_seen}" "${MAX_GLIBC}" | sort -V | tail -1)"
            check "glibc requirement is <= ${MAX_GLIBC}" test "${highest}" = "${MAX_GLIBC}"
        fi

        log "Checking shared library dependencies"
        # Everything here is part of a base libc install. Anything else (libssl,
        # libgdbm, ...) would have to be shipped. musl folds every one of these
        # into a single libc.musl-<arch>.so.1, which doubles as its loader.
        #
        # libcrypt is deliberately absent: its SONAME differs between libxcrypt
        # builds (.so.1 vs .so.2) and glibc dropped its own copy in 2.39, so it
        # is linked statically instead. See build-unix.sh.
        allowed='^(libc|libm|libdl|libpthread|librt|libutil|libc\.musl-.*|ld-musl-.*|ld-linux.*|linux-vdso)\.so'
        while read -r need; do
            [[ -z "${need}" ]] && continue
            if [[ "${need}" =~ ${allowed} ]]; then
                printf 'ok   - permitted dependency: %s\n' "${need}"
            else
                printf 'FAIL - unexpected dependency: %s\n' "${need}"
                failures=$((failures + 1))
            fi
        done < <(objdump -p "${perl_bin}" 2>/dev/null | awk '/NEEDED/ {print $2}')
    else
        warn "objdump unavailable; skipping ELF checks"
    fi
    ;;
Darwin)
    log "Checking macOS deployment target and dependencies"
    if command -v otool >/dev/null 2>&1; then
        otool -l "${perl_bin}" | grep -A3 -E 'LC_(BUILD_VERSION|VERSION_MIN_MACOSX)' | sed 's/^/#   /' || true
        # Only system frameworks may be linked; a Homebrew path here means the
        # artifact would fail on a machine without that formula installed.
        while read -r dep; do
            case "${dep}" in
                /usr/lib/*|/System/Library/*) printf 'ok   - system dependency: %s\n' "${dep}" ;;
                *) printf 'FAIL - non-system dependency: %s\n' "${dep}"; failures=$((failures + 1)) ;;
            esac
        done < <(otool -L "${perl_bin}" | tail -n +2 | awk '{print $1}')
    else
        warn "otool unavailable; skipping Mach-O checks"
    fi
    ;;
esac

# --- 2b. the binaries carry no debug info ------------------------------------
#
# %Config is checked by smoke.pl; this checks what is actually in the files,
# which is what catches a stripping step that silently failed.

log "Checking that binaries are stripped"
if command -v readelf >/dev/null 2>&1; then
    while read -r obj; do
        if readelf -S "${obj}" 2>/dev/null | grep -q '\.debug_info'; then
            printf 'FAIL - carries debug info: %s\n' "${obj#"${root}"/}"
            failures=$((failures + 1))
        fi
    done < <(find "${root}" -type f \( -name '*.so' -o -name 'perl' \))
    printf 'ok   - no .debug_info sections found\n'
elif command -v file >/dev/null 2>&1; then
    check "bin/perl is stripped" bash -c "file '${perl_bin}' | grep -q 'not stripped' && exit 1 || exit 0"
fi

# --- 3. functional smoke test, in place -------------------------------------

log "Running smoke test in place"
if "${perl_bin}" "${REPO_ROOT}/test/smoke.pl" \
        --version "${PERL_VERSION}" --dynaloader "${DYNALOADER}"; then
    printf 'ok   - smoke test passes in place\n'
else
    printf 'FAIL - smoke test in place\n'
    failures=$((failures + 1))
fi

# --- 4. the same tree, moved -------------------------------------------------
#
# The whole point of the distribution. Bazel unpacks into a content-addressed
# path and materialises runfiles elsewhere, so the tree must not care where it
# lives or how deep the path is.

log "Running smoke test after relocation"
moved="${WORK}/relocated/a/much/deeper/destination"
mkdir -p "$(dirname "${moved}")"
mv "${root}" "${moved}"
if "${moved}/bin/perl" "${REPO_ROOT}/test/smoke.pl" \
        --version "${PERL_VERSION}" --dynaloader "${DYNALOADER}"; then
    printf 'ok   - smoke test passes after relocation\n'
else
    printf 'FAIL - smoke test after relocation\n'
    failures=$((failures + 1))
fi

# --- 5. toolchain contract expected by rules_perl ----------------------------
#
# perl_toolchain resolves these by globbing the tree; if they move or vanish,
# toolchain setup fails with a confusing error at analysis time instead.

log "Checking the rules_perl toolchain contract"
check "bin/perl is present"  test -x "${moved}/bin/perl"
check "bin/xsubpp is present" test -f "${moved}/bin/xsubpp"
check "CORE headers are present" \
    bash -c "ls \"${moved}\"/lib/*/*/CORE/perl.h >/dev/null 2>&1"
check "CORE/config.h is present" \
    bash -c "ls \"${moved}\"/lib/*/*/CORE/config.h >/dev/null 2>&1"

# --- summary -----------------------------------------------------------------

echo
if (( failures )); then
    die "${failures} check(s) failed for ${ARCHIVE}"
fi
log "All checks passed for $(basename "${ARCHIVE}")"
