#!/usr/bin/env bash
# Turn a freshly `make install`ed Perl tree into a relocatable, slimmed-down
# distribution. Safe to run only once, on a staging prefix.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/build/common.sh"

PREFIX=""
PERL_VERSION=""
PLATFORM=""
SCRUB_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --perl-version) PERL_VERSION="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --scrub-dir) SCRUB_DIR="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -d "${PREFIX}" ]] || die "--prefix must be an existing directory"
[[ -n "${PERL_VERSION}" ]] || die "--perl-version is required"

archdir="$(echo "${PREFIX}/lib/${PERL_VERSION}"/*-*/CORE | head -1)"
archdir="$(dirname "${archdir}")"
[[ -d "${archdir}" ]] || die "could not locate the architecture lib directory"

# --- 0. make the staging tree writable --------------------------------------
#
# `make install` leaves the tree read-only, which blocks both strip and the
# %Config rewrite. Modes are normalised again at the end.

chmod -R u+w "${PREFIX}"

# --- 1. prune ---------------------------------------------------------------
#
# rules_perl globs the whole tree into the runfiles of every Perl action, so
# bytes here are paid for on every build that uses the toolchain.

log "Pruning"
rm -rf "${PREFIX}/lib/${PERL_VERSION}/pod"
rm -rf "${PREFIX}/man" "${PREFIX}/share/man" "${PREFIX}/html"
# Unicode normalisation *test* data, not needed at runtime.
rm -f "${PREFIX}/lib/${PERL_VERSION}/unicore/TestNorm.pl"
# .packlist / perllocal.pod record absolute install paths and are only consulted
# by uninstallers.
find "${PREFIX}" -name '.packlist' -delete
find "${PREFIX}" -name 'perllocal.pod' -delete
# Stand-alone .pod files. Inline POD inside .pm files is deliberately kept:
# some modules read their own documentation at runtime.
find "${PREFIX}" -name '*.pod' -delete

# --- 2. strip ---------------------------------------------------------------
#
# The interpreter's dynamic symbol table must survive: XS objects resolve perl
# symbols against the executable at load time (via -Wl,-E on Linux and
# -undefined dynamic_lookup on macOS). Both invocations below touch only debug
# and local symbols.

log "Stripping"
case "${PLATFORM}" in
    *linux*)
        find "${PREFIX}" -name '*.so' -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
        strip --strip-unneeded "${PREFIX}/bin/perl" 2>/dev/null || true
        ;;
    *macos*)
        find "${PREFIX}" -name '*.bundle' -type f -exec strip -S -x {} + 2>/dev/null || true
        strip -S "${PREFIX}/bin/perl" 2>/dev/null || true
        ;;
esac

# --- 3. de-duplicate the versioned interpreter ------------------------------

if [[ -f "${PREFIX}/bin/perl${PERL_VERSION}" ]]; then
    log "Linking bin/perl${PERL_VERSION} -> perl"
    rm -f "${PREFIX}/bin/perl${PERL_VERSION}"
    ln -s perl "${PREFIX}/bin/perl${PERL_VERSION}"
fi

# --- 4. rewrite the staging prefix out of %Config ---------------------------
#
# `.../` at the start of a path is expanded at runtime to the directory holding
# the perl binary, i.e. <root>/bin. So the prefix itself becomes ".../..".
# Order matters: the perl binary is rewritten first so it collapses to
# ".../perl" rather than ".../../bin/perl".

log "Rewriting build paths in %Config"
config_files=(
    "${archdir}/Config_heavy.pl"
    "${archdir}/Config.pm"
    "${archdir}/CORE/config.h"
)
for f in "${config_files[@]}"; do
    [[ -f "${f}" ]] || continue
    perl_rewrite "${f}" "${PREFIX}"
done

# --- 4a. drop build-time-only -L flags --------------------------------------
#
# The glibc builds add a -L pointing at a scratch directory holding
# libcrypt.a (see build-unix.sh). Configure records it in ldflags, lddlflags
# and config_args, where it is both a build-host path and a source of
# non-determinism, since the directory name changes on every build. It has no
# meaning once the interpreter is linked, so remove it.

if [[ -n "${SCRUB_DIR}" ]]; then
    log "Scrubbing build-time -L flags"
    "${PYTHON}" - "${archdir}/Config_heavy.pl" "${SCRUB_DIR}" <<'PY'
import os, re, stat, sys

path, scrub = sys.argv[1], sys.argv[2].rstrip("/")

with open(path, encoding="utf-8", errors="surrogateescape") as fh:
    text = fh.read()

# The -L flag and whatever directory hangs off it, plus one trailing space so
# the surrounding flags do not end up glued together.
new = re.sub(r"-L%s[^\s'\"]*\s?" % re.escape(scrub), "", text)
if new == text:
    sys.exit(0)

mode = stat.S_IMODE(os.stat(path).st_mode)
os.chmod(path, mode | stat.S_IWUSR)
try:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(new)
finally:
    os.chmod(path, mode)
PY
fi

# --- 4b. erase the build machine's identity ---------------------------------
#
# Configure records `uname -a` verbatim, in $Config{myuname} and again in the
# "Target system" header comment of Config_heavy.pl and CORE/config.h. Inside
# a build container that string carries the container ID, so it names a machine
# that never existed anywhere but that one build, and differs on every run.
# Nothing reads it afterwards -- Configure uses it to pick hints, and past that
# it is only ever displayed -- so replace it with a fixed placeholder.
#
# The configuration timestamp in the same header is left alone: it is real
# provenance rather than host identity, and $Config{cf_time} has to keep
# matching it or bin/perlbug reports a mismatched build.
#
# $Config{osvers} is left alone too. It is equally a build-host fact, but
# unlike myuname it is a documented value that CPAN modules do branch on, and
# any replacement would be just as wrong as the kernel we happened to build on.
# See the note in README.md.

log "Normalising the recorded build host"
"${PYTHON}" - "${archdir}" <<'PY'
import os, re, stat, sys

archdir = sys.argv[1]
heavy = os.path.join(archdir, "Config_heavy.pl")

with open(heavy, encoding="utf-8", errors="surrogateescape") as fh:
    osname = re.search(r"^osname='([^']*)'", fh.read(), re.M)
placeholder = "%s portable-perl" % (osname.group(1) if osname else "unknown")

def rewrite(path, subs):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        text = new = fh.read()
    for pattern, repl in subs:
        new = re.sub(pattern, repl, new, flags=re.M)
    if new == text:
        return
    mode = stat.S_IMODE(os.stat(path).st_mode)
    os.chmod(path, mode | stat.S_IWUSR)
    try:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new)
    finally:
        os.chmod(path, mode)
    print("#   normalised %s" % path)

# "Target system" only ever appears in the generated header comment, so keeping
# whatever comment leader precedes it is enough to cover both file formats.
target = (r"^(.*Target system\s*:\s*).*$", lambda m: m.group(1) + placeholder)

rewrite(heavy, [(r"^myuname='[^']*'", "myuname='%s'" % placeholder), target])
rewrite(os.path.join(archdir, "CORE", "config.h"), [target])
PY

# --- 4c. widen the set of %Config values that get relocated -----------------
#
# Config_heavy.pl relocates a ".../"-prefixed value only for keys on a hardcoded
# list, and upstream's list covers just the `*exp` and `install*` variants. The
# plain spellings (prefix, privlib, perlpath, startperl, ...) are left literal,
# which means $Config{prefix} would come back as the uninterpreted string
# ".../..". Extend the list, and teach the substitution about the leading "#!"
# that startperl carries.
#
# Config.pm additionally inlines a small bootstrap hash that shadows
# Config_heavy.pl for a handful of keys; raw ".../" values there need the same
# relocate_inc() wrapper.

log "Extending %Config relocation coverage"
"${PYTHON}" - "${archdir}" <<'PY'
import os, re, stat, sys

archdir = sys.argv[1]

RELOCATED_KEYS = """
archlib archlibexp bin binexp initialinstalllocation installarchlib installbin
installprefix installprefixexp installprivlib installscript installsitearch
installsitebin installsitelib installsitescript perlpath prefix prefixexp
privlib privlibexp scriptdir scriptdirexp sitearch sitearchexp sitebin
sitebinexp sitelib sitelib_stem sitelibexp siteprefix siteprefixexp sitescript
sitescriptexp startperl
""".split()


def edit(path, transform):
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()
    new = transform(text)
    if new == text:
        return False
    mode = stat.S_IMODE(os.stat(path).st_mode)
    os.chmod(path, mode | stat.S_IWUSR)
    try:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new)
    finally:
        os.chmod(path, mode)
    return True


def widen_heavy(text):
    loop = re.search(
        r"foreach my \$what \(qw\([^)]*\)\) \{\n\s*s/\^\(\$what=\)[^\n]*\n\}", text)
    if not loop:
        sys.exit("could not find the relocation loop in Config_heavy.pl")
    replacement = (
        "foreach my $what (qw(%s)) {\n"
        "    s/^($what=)(['\"])(#!)?(.*?)\\2"
        "/$1 . $2 . ($3 || \"\") . relocate_inc($4) . $2/me;\n}"
    ) % " ".join(RELOCATED_KEYS)
    return text[:loop.start()] + replacement + text[loop.end():]


def wrap_inline(text):
    return re.sub(r"^(\s+\w+ => )'(\.\.\./[^']*)',$",
                  r"\1relocate_inc('\2'),", text, flags=re.M)


heavy = os.path.join(archdir, "Config_heavy.pl")
if not os.path.exists(heavy):
    sys.exit("Config_heavy.pl not found in %s" % archdir)
edit(heavy, widen_heavy)
edit(os.path.join(archdir, "Config.pm"), wrap_inline)
PY

# --- 5. make bin/ scripts relocatable ---------------------------------------

log "Rewriting shebangs"
for script in "${PREFIX}"/bin/*; do
    [[ -f "${script}" ]] || continue                 # skips the perlX.Y.Z symlink
    [[ -L "${script}" ]] && continue
    base="$(basename "${script}")"
    [[ "${base}" == "perl" ]] && continue
    grep -qI . "${script}" || continue               # binary
    head -n1 "${script}" | grep -q '^#!.*perl' || continue

    relocatable_shebang "${script}"
    # The classic `eval 'exec <path>/perl -S $0 ...'` prologue also embeds the
    # build path. It is never executed (it is guarded by an undefined variable),
    # but leaving an absolute build path in the artifact is not acceptable.
    perl_rewrite "${script}" "${PREFIX}" --bare-perl
done

# --- 6. normalise permissions ------------------------------------------------
#
# Deterministic modes keep the archive from depending on the build machine's
# umask.

log "Normalising permissions"
find "${PREFIX}" -type d -exec chmod 0755 {} +
find "${PREFIX}" -type f -perm -u+x -exec chmod 0755 {} +
find "${PREFIX}" -type f ! -perm -u+x -exec chmod 0644 {} +

log "Post-processing complete"
