# Shared helpers for the POSIX build scripts. Sourced, not executed.
# shellcheck shell=bash

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Locate a Python 3 interpreter.
#
# Not as simple as calling `python3`: the manylinux images keep their
# interpreters outside PATH under /opt/python and leave `python` pointing at
# 2.7, so a bare `python3` is not resolvable there. Override with
# PORTABLE_PERL_PYTHON if needed.
find_python() {
    local candidate resolved
    for candidate in \
        "${PORTABLE_PERL_PYTHON:-}" \
        python3 python \
        /usr/local/bin/python3 /opt/python/cp3*/bin/python3
    do
        [[ -n "${candidate}" ]] || continue
        resolved="$(command -v "${candidate}" 2>/dev/null)" || continue
        "${resolved}" -c 'import sys; sys.exit(sys.version_info < (3, 6))' 2>/dev/null \
            || continue
        printf '%s\n' "${resolved}"
        return 0
    done
    return 1
}

PYTHON="$(find_python)" \
    || die "no Python 3 interpreter found; set PORTABLE_PERL_PYTHON"
readonly PYTHON

# json_get <file> <key> [<key>...]
#
# Minimal JSON reader so the build scripts do not depend on jq being present in
# the manylinux containers or on the macOS runners. Keys are passed as separate
# arguments rather than a dotted path, because Perl version numbers are
# themselves dotted.
json_get() {
    "${PYTHON}" -c '
import json, sys
with open(sys.argv[1]) as fh:
    node = json.load(fh)
for part in sys.argv[2:]:
    if not isinstance(node, dict) or part not in node:
        sys.exit(0)
    node = node[part]
print(node)
' "$@"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# fetch <url> <dest> <expected-sha256>
fetch() {
    local url="$1" dest="$2" want="$3" got
    log "Fetching ${url}"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "${dest}" "${url}" || die "download failed: ${url}"
    got="$(sha256_of "${dest}")"
    [[ "${got}" == "${want}" ]] \
        || die "checksum mismatch for ${url}: expected ${want}, got ${got}"
}

# archive_tree <parent-dir> <tree-name> <output.tar.xz>
#
# Packs <parent-dir>/<tree-name> with ownership normalised to 0:0, so the
# archive depends only on the tree's contents and not on the build machine's
# uid or umask. Both tar dialects are handled: GNU tar in the Linux containers,
# bsdtar on macOS -- bsdtar spells the ownership flags differently and rejects
# --mode outright. File modes were already normalised by postprocess-unix.sh,
# so nothing is lost by not passing --mode to it.
archive_tree() {
    local parent="$1" name="$2" out="$3" tar_bin
    command -v xz >/dev/null 2>&1 || die "xz is required to create ${out}"

    if command -v gtar >/dev/null 2>&1; then
        tar_bin=gtar
    else
        tar_bin=tar
    fi

    if "${tar_bin}" --version 2>/dev/null | grep -q 'GNU tar'; then
        "${tar_bin}" --create --directory "${parent}" \
            --owner=0 --group=0 --numeric-owner --mode='go-w' --format=gnu \
            "${name}"
    else
        tar --create --directory "${parent}" \
            --uid 0 --gid 0 --numeric-owner --format=gnutar \
            "${name}"
    fi | xz -9 -T0 > "${out}"
}

# install_cpanm <prefix> <workdir>
#
# Drops the fatpacked cpanm into <prefix>/bin with a relocatable shebang.
install_cpanm() {
    local prefix="$1" work="$2" repo_root url sha tarball dir
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    url="$(json_get "${repo_root}/versions.json" cpanm url)"
    sha="$(json_get "${repo_root}/versions.json" cpanm sha256)"
    [[ -n "${url}" ]] || die "cpanm is not listed in versions.json"

    tarball="${work}/cpanm.tar.gz"
    fetch "${url}" "${tarball}" "${sha}"

    dir="${work}/cpanm-src"
    mkdir -p "${dir}"
    tar xzf "${tarball}" -C "${dir}" --strip-components=1

    log "Bundling cpanm"
    cp "${dir}/bin/cpanm" "${prefix}/bin/cpanm"
    chmod 0755 "${prefix}/bin/cpanm"
    relocatable_shebang "${prefix}/bin/cpanm"
}

# perl_rewrite <file> <prefix> [--bare-perl]
#
# Replaces every mention of the staging prefix with a form that resolves at
# runtime. `.../` is expanded by perl to the directory containing the running
# interpreter, so the prefix itself maps to ".../..".
#
# With --bare-perl the interpreter is rewritten to a plain `perl` instead. That
# is used for the `eval 'exec <path>/perl -S $0'` prologue in bin/ scripts,
# which is dead code but must not carry a build path.
perl_rewrite() {
    local file="$1" prefix="$2" mode="${3:-}"
    "${PYTHON}" - "${file}" "${prefix}" "${mode}" <<'PY'
import os, stat, sys

path, prefix, mode = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
interpreter = "perl" if mode == "--bare-perl" else ".../perl"

with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
    text = fh.read()

# Longest match first, so <prefix>/bin/perl never degrades to ".../../bin/perl".
new = text.replace(prefix + "/bin/perl", interpreter).replace(prefix, ".../..")
if new == text:
    sys.exit(0)

# `make install` leaves most of the tree read-only, so widen the mode for the
# rewrite and put the original back afterwards.
original = stat.S_IMODE(os.stat(path).st_mode)
os.chmod(path, original | stat.S_IWUSR)
try:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(new)
finally:
    os.chmod(path, original)
PY
}

# relocatable_shebang <script>
#
# Replaces a script's `#!<abs path>/perl` line with a /bin/sh trampoline that
# re-executes the sibling perl. `perl -x` makes the interpreter skip forward to
# the `#!perl` line, so the Perl body below is unaffected.
relocatable_shebang() {
    local script="$1" tmp
    tmp="${script}.portable-perl.tmp"
    {
        printf '#!/bin/sh\n'
        # shellcheck disable=SC2016  # the shell text must be emitted verbatim
        printf 'exec "$(dirname "$0")"/perl -x "$0" "$@"\n'
        printf '#!perl\n'
        tail -n +2 "${script}"
    } > "${tmp}"
    chmod --reference="${script}" "${tmp}" 2>/dev/null || chmod 0755 "${tmp}"
    mv "${tmp}" "${script}"
}
