#!/usr/bin/env perl
#
# Cross-platform acceptance test for a built distribution. Run it with the
# interpreter under test:
#
#     <dist>/bin/perl test/smoke.pl --version 5.44.0
#
# It is deliberately written against core modules only, and must pass on all
# six supported platforms.
use strict;
use warnings;

use Config;
use File::Basename qw(dirname basename);
use File::Spec;
use File::Temp qw(tempdir);

my $expected_version = '';
# Whether this flavour is expected to be able to dlopen XS objects built after
# the interpreter. False for the fully static musl build.
my $expect_dynaloader = 1;

for (my $i = 0; $i < @ARGV; $i++) {
    $expected_version  = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--version';
    $expect_dynaloader = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--dynaloader';
}

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { $pass++; print "ok   - $desc\n" }
    else       { $fail++; print "FAIL - $desc\n" }
    return $cond;
}

# Normalise for comparison: unify separators, collapse . and .. lexically, and
# fold case on Windows. The collapse is lexical rather than via Cwd::abs_path so
# that paths which do not exist yet (an empty sitelib, say) still compare, and
# so that symlinked temp dirs such as macOS's /tmp do not resolve differently on
# the two sides of the comparison.
sub canon {
    my ($p) = @_;
    return '' unless defined $p;
    $p =~ s{\\}{/}g;

    my $leading = $p =~ m{^/} ? '/' : '';
    my @out;
    for my $seg (split m{/+}, $p) {
        next if $seg eq '' || $seg eq '.';
        if ($seg eq '..' && @out && $out[-1] ne '..') { pop @out; next }
        push @out, $seg;
    }
    $p = $leading . join '/', @out;
    $p =~ s{/+$}{};
    return $^O eq 'MSWin32' ? lc $p : $p;
}

my $bindir = dirname($^X);
my $root   = canon(File::Spec->catdir($bindir, File::Spec->updir));

print "# interpreter : $^X\n";
print "# dist root   : $root\n";
print "# archname    : $Config{archname}\n";
print "# osname      : $Config{osname}\n";

# --- version ----------------------------------------------------------------

if ($expected_version) {
    my $got = sprintf '%vd', $^V;
    ok($got eq $expected_version, "interpreter is $expected_version (got $got)");
}

# --- build configuration invariants -----------------------------------------
#
# These are the exact settings the relocatable + XS-capable layout depends on.

if ($expect_dynaloader) {
    ok($Config{usedl} eq 'define', 'DynaLoader is enabled (XS objects can be loaded)');
} else {
    # The fully static flavour. Core extensions are linked into the interpreter
    # instead, so they still work; only externally built XS cannot be loaded.
    ok($Config{usedl} ne 'define', 'DynaLoader is disabled, as expected for the static flavour');
    ok(scalar(@{[ split ' ', ($Config{static_ext} // '') ]}) > 0,
        'core extensions are linked in statically');
}

ok($Config{useithreads} eq 'define', 'ithreads are enabled');

if ($^O eq 'MSWin32') {
    # Windows has no -Duserelocatableinc; win32.c derives @INC from
    # GetModuleFileNameW instead. win32/Makefile also always builds a shared
    # perl5xx.dll, which costs nothing here because Windows searches the
    # directory holding perl.exe before anything else -- as long as the DLL is
    # actually in the archive, which is what this checks.
    opendir my $dh, $bindir or die "cannot read $bindir: $!";
    my @dll = grep { /^perl\d*\.dll$/i } readdir $dh;
    closedir $dh;
    ok(scalar(@dll), "the perl DLL ships next to perl.exe (@dll)");
} else {
    # -Duserelocatableinc is mutually exclusive with a shared libperl, so on
    # Unix libperl has to be linked into the interpreter.
    ok($Config{userelocatableinc} eq 'define', 'userelocatableinc is set');
    ok($Config{useshrplib} ne 'true', 'libperl is linked into the interpreter, not shared');
}

# --- relocation --------------------------------------------------------------
#
# Every search path must live under the unpacked tree. If any of these point at
# the machine that produced the artifact, the distribution is not relocatable.

for my $dir (@INC) {
    next if ref $dir;
    ok(index(canon($dir), $root) == 0, "\@INC entry is inside the dist: $dir");
}

for my $key (qw(prefix privlib archlib sitelib sitearch perlpath scriptdir)) {
    my $val = $Config{$key};
    next unless defined $val && length $val;
    ok(index(canon($val), $root) == 0, "\$Config{$key} is inside the dist: $val");
}

# startperl embeds a shebang, so strip the marker before comparing. On Windows
# it is just "#!perl" with no path at all, which is nothing to check.
{
    my $sp = $Config{startperl} // '';
    $sp =~ s/^#!//;
    ok(index(canon($sp), $root) == 0, "\$Config{startperl} is inside the dist: $Config{startperl}")
        if length $sp && $sp =~ m{[\\/]};
}

# --- no build-host path leakage ---------------------------------------------
#
# Catch a staging prefix that survived post-processing. Anything still holding
# a literal "..." marker means a path was never expanded.

{
    # config_args / config_argN echo the Configure command line verbatim, which
    # legitimately contains the rewritten -Dprefix=.../.. and is never used as a
    # path. Everything else must have been expanded.
    my @unexpanded = grep {
        $_ !~ /^config_arg/
            && defined $Config{$_}
            && $Config{$_} =~ m{\Q.../\E}
    } sort keys %Config;
    ok(!@unexpanded, 'no unexpanded ".../" markers in %Config')
        or print "#   offenders: @unexpanded\n";
}

# --- release build, not a debug build ---------------------------------------
#
# A DEBUGGING perl is substantially slower and much larger. -g (or -Zi on MSVC)
# means debug info was emitted, which also tends to embed build-host paths.

{
    my $optimize = $Config{optimize} // '';
    my $ccflags  = $Config{ccflags} // '';

    ok($ccflags !~ /-DDEBUGGING\b/, "ccflags has no -DDEBUGGING ($ccflags)");
    ok($optimize !~ /(?:^|\s)-g\d?\b/, "optimize has no -g ($optimize)");
    ok($optimize !~ /(?:^|\s)[-\/]Zi\b/, "optimize has no /Zi ($optimize)");
    ok($optimize =~ m{(?:^|\s)[-/]O}, "an optimisation level is set ($optimize)");

    # perl -V lists DEBUGGING among its compile-time options when enabled.
    my @opts = split ' ', ($Config{ccflags_uselargefiles} // '');
    ok(!grep({ $_ eq '-DDEBUGGING' } @opts), 'no DEBUGGING in compile-time options');
}

# --- XS modules actually dlopen ---------------------------------------------
#
# This is the property that -Uusedl or a fully static musl build would break,
# and the one rules_perl's perl_xs rule depends on.

my @xs_modules = qw(
    List::Util  POSIX     Encode    Storable
    Fcntl       Cwd       Socket    Time::HiRes
    Data::Dumper  MIME::Base64  Digest::MD5  Hash::Util
);
for my $mod (@xs_modules) {
    my $loaded = eval "require $mod; 1";
    ok($loaded, "XS module loads: $mod") or print "#   $@";
}

# Prove one of them really executes compiled code rather than a pure-perl fallback.
{
    require List::Util;
    ok(List::Util::sum(1 .. 10) == 55, 'List::Util::sum returns 55 (XS code ran)');
}

# --- crypt() ------------------------------------------------------------------
#
# On the glibc builds libcrypt is linked statically, precisely so the artifact
# does not depend on a libxcrypt SONAME that varies between distributions.
# Check the builtin still works rather than just that it linked.

if (($Config{d_crypt} // '') eq 'define') {
    my $hashed = eval { crypt('portable-perl', 'ab') };
    ok(defined $hashed && length($hashed) >= 13, 'crypt() works')
        or print "#   $@";
}

# --- pure-perl core modules --------------------------------------------------

for my $mod (qw(Getopt::Long File::Path File::Temp Test::More ExtUtils::MakeMaker
                ExtUtils::ParseXS Encode::Encoding JSON::PP)) {
    ok(eval "require $mod; 1", "core module loads: $mod");
}

# --- xsubpp ------------------------------------------------------------------
#
# rules_perl invokes bin/xsubpp directly as the executable of a build action, so
# it has to work as a standalone program from the unpacked tree.

{
    my $xsubpp = File::Spec->catfile($bindir, 'xsubpp');
    $xsubpp = File::Spec->catfile($bindir, 'xsubpp.bat') if !-e $xsubpp && $^O eq 'MSWin32';
    ok(-e $xsubpp, "xsubpp exists at $xsubpp");

    if (-e $xsubpp) {
        my $tmp = tempdir(CLEANUP => 1);
        my $xs  = File::Spec->catfile($tmp, 'Smoke.xs');
        open my $fh, '>', $xs or die "cannot write $xs: $!";
        print {$fh} <<'XS';
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = Smoke   PACKAGE = Smoke

int
answer()
    CODE:
        RETVAL = 42;
    OUTPUT:
        RETVAL
XS
        close $fh;

        my $out = `"$xsubpp" "$xs" 2>&1`;
        ok($? == 0, 'xsubpp exits cleanly') or print "#   $out\n";
        ok($out =~ /XS_Smoke_answer|boot_Smoke/, 'xsubpp generated C source for the XS stub');
    }
}

# --- bundled tooling ---------------------------------------------------------

{
    my $cpanm = File::Spec->catfile($bindir, 'cpanm');
    $cpanm = File::Spec->catfile($bindir, 'cpanm.bat') if !-e $cpanm && $^O eq 'MSWin32';
    ok(-e $cpanm, 'cpanm is bundled');
}

# --- summary -----------------------------------------------------------------

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
