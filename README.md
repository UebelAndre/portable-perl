# portable-perl

Relocatable, self-contained Perl distributions for Linux, macOS and Windows on
x86_64 and aarch64, published as GitHub releases and consumed by
[`rules_perl`](https://github.com/bazel-contrib/rules_perl).

Each release is a `.tar.xz` holding a complete Perl installation that can be
unpacked anywhere and moved afterwards. `@INC`, `%Config` and the shebangs of
the bundled scripts are all resolved at runtime relative to the interpreter, so
nothing in the archive refers to the machine that produced it.

## Releases

A release is a **build** of the pipeline, tagged `YYYYMMDD` (or `YYYYMMDD.N`
for a second train on the same day). It contains every Perl version listed in
[`versions.json`](versions.json), on every platform, built and verified by the
same revision of the build scripts, with one `SHA256SUMS` and a provenance
attestation per archive.

The unit is the build rather than the Perl version because that is what
changes together: a fix to how the archives are made portable applies to every
version alike, so it ships as a new train that rebuilds the whole catalogue,
and no version is left on an older build known to be wrong. Consumers pin a
build together with a Perl version:

```
https://github.com/UebelAndre/portable-perl/releases/download/<build>/perl-<version>-<platform>.tar.xz
```

## Artifacts

Each release contains, for every Perl version, one archive per row below,
named `perl-<version>-<platform>.tar.xz`, plus a `SHA256SUMS` file.

| Platform | libc | XS at runtime | Notes |
| --- | --- | --- | --- |
| `x86_64-linux-gnu` | glibc ≥ 2.17 | yes | built in `manylinux2014` |
| `aarch64-linux-gnu` | glibc ≥ 2.17 | yes | built in `manylinux2014` |
| `x86_64-linux-musl` | musl | yes | built on Alpine |
| `aarch64-linux-musl` | musl | yes | built on Alpine |
| `x86_64-linux-musl-static` | none | **no** | one static binary, no loader |
| `aarch64-linux-musl-static` | none | **no** | one static binary, no loader |
| `x86_64-macos` | libSystem | yes | `MACOSX_DEPLOYMENT_TARGET=10.15` |
| `aarch64-macos` | libSystem | yes | `MACOSX_DEPLOYMENT_TARGET=11.0` |
| `x86_64-windows-msvc` | UCRT + VC runtime | yes | upstream Perl, Visual C++ |
| `aarch64-windows-msvc` | UCRT + VC runtime | yes | upstream Perl, Visual C++ |
| `x86_64-windows-gnu` | UCRT + libgcc | yes | upstream Perl, mingw-w64 GCC |

This repository does not designate a default. Which flavour to fetch is
`rules_perl`'s decision, expressed through its own platform constraints.

### Which Windows flavour

Both are upstream Perl, built from the same tarball, relocatable the same
way, on the same C runtime (the UCRT). They differ in the compiler, and an XS
module has to be built with the compiler family its perl was built with — so
the choice is really about which compiler will build your XS.

**`-msvc`** is built with `win32/Makefile` and Visual C++. It matches Bazel's
autoconfigured Windows C++ toolchain, so `perl_xs` compiles with the same
`cl.exe` as every `cc_library` in the build. It is also the only flavour for
ARM64. Two rules come with it: XS must be compiled against the release CRT
(`/MD`, never `/MDd`), and the `vcruntime140.dll` vendored in `bin\` shadows
any newer copy in `System32`, so XS built with a *newer* toolset than the one
that produced the archive could need an export it lacks.

**`-gnu`** is built with `win32/GNUmakefile` and mingw-w64 GCC from MSYS2's
UCRT64 environment — the same compiler and CRT pairing as current Strawberry
Perl, which is what the overwhelming majority of CPAN's Windows testing runs
on. XS modules and `Makefile.PL`s written against Strawberry meet the ABI they
expect here. Using it from Bazel means registering a mingw-w64 C++ toolchain
for `perl_xs`. It is not Strawberry: there is no bundled compiler and no
bundled C libraries, which is what keeps it at ~12 MB rather than ~400.

### Which Linux flavour

**`-gnu` is the one to reach for.** It is built inside `manylinux2014`, so it
requires nothing newer than glibc 2.17 (RHEL 7, Ubuntu 14.04) and links only
against libraries that are part of a base glibc system.

**`-musl`** is for musl-based distributions such as Alpine. It is dynamically
linked and, like `-gnu`, can `dlopen` XS objects.

**`-musl-static`** is a single dependency-free executable: no `PT_INTERP`, no
`DT_NEEDED` entries, verified to run on a glibc host with no musl installed.
The price is that **it cannot load XS modules built after the interpreter**.
musl's static `dlopen` is a stub that always fails, so the build sets
`-Uusedl` and links every core extension directly into the binary instead.
Core XS (`List::Util`, `POSIX`, `Encode`, ...) works normally; anything
produced by `rules_perl`'s `perl_xs` rule will not load. Choose this flavour
only for pure-Perl workloads where maximum hermeticity matters more than XS.

## Verifying a download

```sh
sha256sum -c SHA256SUMS

# Provenance: binds the archive's digest to the workflow run and commit
# that produced it.
gh attestation verify perl-5.44.0-x86_64-linux-gnu.tar.xz \
  --repo UebelAndre/portable-perl
```

## What is in the archive

```
perl-<version>-<platform>/
  bin/            perl, xsubpp, cpanm, and the usual core utilities
  lib/<version>/  core modules, with <archname>/CORE/ holding the XS headers
  lib/site_perl/  empty, for anything installed later
```

Everything is built for release: `-O3` on Unix, `-O1 -GL` with MSVC (upstream's
deliberate choice — `-O1` produces smaller code that measures faster than `-O2`
for the interpreter loop), `-O2` with mingw-w64 GCC 15.1 or later (upstream
defaults to `-Os` because of a GCC miscompile, GH #20081, that 15.1 fixed), no
`DEBUGGING`, no `-g`/`-Zi`, and binaries stripped of debug and local symbols. ithreads are on everywhere, so `%Config` is uniform
across platforms.

Documentation and install metadata are pruned — standalone `*.pod`, `man/`,
`html/`, `.packlist`, `perllocal.pod` — because `rules_perl` globs the whole
tree into the runfiles of every Perl action, so size here is paid on every
build that uses the toolchain. POD embedded in `.pm` files is kept, since some
modules read their own documentation at runtime. A Linux archive lands around
7.5 MB compressed.

## How relocation works

On Unix the builds use `-Duserelocatableinc`, which stores paths as `.../<rel>`
and expands them at runtime against `dirname($^X)`. That flag is mutually
exclusive with a shared `libperl`, so `libperl` is linked into the interpreter
(`-Uuseshrplib`); this is also what lets XS objects resolve interpreter symbols
through `-Wl,-E`.

Two extra steps happen after `make install`:

- Upstream's relocation loop in `Config_heavy.pl` only covers the `*exp` and
  `install*` keys, and `Config.pm` carries an inline bootstrap hash that
  shadows it for a few more. Both are patched so that plain keys such as
  `prefix`, `privlib`, `perlpath` and `startperl` also expand.
- Scripts in `bin/` get a `/bin/sh` trampoline that re-executes them under the
  neighbouring `perl` (`exec "$(dirname "$0")"/perl -x "$0" "$@"`), replacing
  the absolute shebang that `make install` writes.

One build-host fact is left in `%Config` on purpose: `$Config{osvers}` records
the kernel of the machine that ran the build, so a `-gnu` archive built on a
6.x runner reports `osvers=6.x` even when it is running on RHEL 7. It is
informational — nothing in the interpreter or in `rules_perl` reads it — and any
substitute would be just as untrue, so it is not overridden. Every other
reference to the builder is normalised away, including `$Config{myuname}` and
the `Target system` header of `Config_heavy.pl` and `CORE/config.h`, which
otherwise carry the build container's ID and differ on every run. The
configuration timestamp is kept: that is provenance rather than host identity,
and `bin/perlbug` checks it against `$Config{cf_time}`.

Windows gets `@INC` for free — `win32.c` derives it from `GetModuleFileNameW` —
but `%Config` does not follow, and things that matter read it: `xsubpp` resolves
the standard typemap under `$Config{privlib}`. So
[`relocate-windows-config.ps1`](build/relocate-windows-config.ps1) applies the
same `.../` treatment there, porting upstream's `relocate_inc` into `Config.pm`
with separator normalisation added, because `$^X` arrives with backslashes.

One string in the Windows archives is a build path by design: `re.dll`, the
`DEBUGGING` build of the regex engine behind `use re 'debug'`, embeds
`__FILE__` of the core headers in its assertion messages, and MSVC always
records those as absolute paths. So the MSVC builds run in the fixed directory
`C:\portable-perl-build`, making that string a constant that is identical on
every builder and names no machine, rather than a random `%TEMP%` path.

Windows Perl always links a shared `perl5xx.dll` — `useshrplib` is not optional
in either Windows makefile — which costs nothing, because Windows searches the
directory holding `perl.exe` first. The compiler's runtime is vendored into
`bin/` next to it for the same reason: `vcruntime140.dll` for `-msvc`,
`libgcc_s_seh-1.dll` and `libwinpthread-1.dll` for `-gnu`. Rather than
hardcode those lists, post-processing reads the import tables of every PE
image in the tree ([`pe-imports.ps1`](build/pe-imports.ps1)) and copies
whatever the toolchain's runtime directory can satisfy; verification then
independently checks that every remaining import is a Windows system DLL.

## Building locally

```sh
# Any Linux flavour. Wraps docker for you and picks the right image
# (manylinux2014 for gnu, Alpine for musl). Native architecture only --
# there is no emulation, so aarch64 artifacts need an arm64 machine.
./build/build-linux.sh --platform x86_64-linux-gnu --verify
./build/build-linux.sh --platform x86_64-linux-musl-static --verify

# macOS, on a Mac
./build/build-unix.sh --platform aarch64-macos

# Windows, from any shell with Visual Studio installed
pwsh ./build/build-windows.ps1 -Platform x86_64-windows-msvc -SetupMsvc

# Windows, with MSYS2's UCRT64 gcc and make installed
#   (pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-make)
pwsh ./build/build-windows.ps1 -Platform x86_64-windows-gnu
```

Add `--run-tests` (`-RunTests` on Windows) to run Perl's own test suite, as CI
does on every build. Archives land in `dist/`.

Verification is a separate step, so a downloaded release can be checked the
same way CI checks a fresh build:

```sh
./build/verify-unix.sh --archive dist/perl-5.44.0-x86_64-linux-gnu.tar.xz

# or inside the matching container, which is what CI does
./build/build-linux.sh --platform x86_64-linux-musl --verify-only
```

It scans for build-host paths, checks the glibc floor and the shared-library
allowlist, confirms nothing carries debug info, and then runs
[`test/smoke.pl`](test/smoke.pl) twice — once in place and once after moving
the tree to a deeper path — including an end-to-end `xsubpp` run and a `dlopen`
of twelve XS modules.

## Adding a Perl version, cutting a release

1. Add an entry to [`versions.json`](versions.json) with the URL and SHA256 of
   the `.tar.gz` from <https://www.cpan.org/src/5.0/>. Point `default` at it if
   pull requests should build it; that is the only version CI builds on every
   change.
2. Run the `release` workflow manually. That builds and verifies the whole
   catalogue without publishing, which is where an older Perl meeting a newer
   compiler shows up. Any version-specific accommodation goes into the build
   scripts, keyed off the version.
3. Push a `YYYYMMDD` tag. The same workflow builds everything again and
   publishes the release.

The same three steps, minus the first, ship a fix to the build scripts.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`versions.json`](versions.json) | the only place versions and checksums are declared |
| [`build/common.sh`](build/common.sh) | shared shell helpers |
| [`build/build-unix.sh`](build/build-unix.sh) | Linux and macOS driver |
| [`build/build-linux.sh`](build/build-linux.sh) | runs the Linux driver in the right container |
| [`build/postprocess-unix.sh`](build/postprocess-unix.sh) | prune, strip, relocate, normalise |
| [`build/verify-unix.sh`](build/verify-unix.sh) | acceptance tests for a built archive |
| [`build/*-windows.ps1`](build/) | the same three stages for MSVC and mingw-w64 |
| [`build/relocate-windows-config.ps1`](build/relocate-windows-config.ps1) | the `.../` relocation applied to a Windows `%Config` |
| [`build/pe-imports.ps1`](build/pe-imports.ps1) | PE import-table reader used to vendor and verify runtime DLLs |
| [`test/smoke.pl`](test/smoke.pl) | cross-platform functional test |

## Licence

The build infrastructure in this repository is Apache 2.0; see
[LICENSE](LICENSE). The distributed artifacts are Perl itself, under the same
terms as Perl (Artistic License 1.0 or GPL 1.0+), and bundle
[cpanm](https://metacpan.org/pod/App::cpanminus) under the same terms.
