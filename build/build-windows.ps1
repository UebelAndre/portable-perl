<#
.SYNOPSIS
    Build a relocatable, portable Perl distribution for Windows.

.DESCRIPTION
    Builds upstream Perl from source with either of the toolchains upstream
    supports:

        *-windows-msvc   win32/Makefile, nmake, Visual C++
        *-windows-gnu    win32/GNUmakefile, GNU make, mingw-w64 GCC (UCRT)

    Windows Perl is inherently relocatable as far as @INC goes: win32.c derives
    it from the location of the running executable (GetModuleFileNameW ->
    get_emd_part). %Config is made relocatable by post-processing.

    MSVC builds must run from a Visual Studio developer environment, or with
    -SetupMsvc so the script locates and imports one itself. GCC builds need a
    mingw-w64 toolchain targeting the UCRT; by default the UCRT64 environment
    of an MSYS2 installed at C:\msys64 is used.

.PARAMETER Platform
    x86_64-windows-msvc, aarch64-windows-msvc or x86_64-windows-gnu.

.PARAMETER MingwRoot
    Root of the mingw-w64 toolchain for the -gnu flavour (the directory holding
    bin\gcc.exe). Defaults to $env:PORTABLE_PERL_MINGW, then C:\msys64\ucrt64.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x86_64-windows-msvc', 'aarch64-windows-msvc', 'x86_64-windows-gnu')]
    [string]$Platform,

    [string]$PerlVersion = '',
    [string]$OutDir = '',
    [string]$MingwRoot = '',
    [switch]$RunTests,
    [switch]$SetupMsvc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist' }

function Write-Log { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Die { param([string]$Message) throw $Message }

# --- resolve inputs ---------------------------------------------------------

$versions = Get-Content (Join-Path $RepoRoot 'versions.json') -Raw | ConvertFrom-Json
if (-not $PerlVersion) { $PerlVersion = $versions.default }

$perlSpec = $versions.perl.$PerlVersion
if (-not $perlSpec) { Die "perl $PerlVersion is not listed in versions.json" }

$toolchain = if ($Platform.EndsWith('-gnu')) { 'gnu' } else { 'msvc' }
$msvcArch  = if ($Platform.StartsWith('aarch64-')) { 'arm64' } else { 'x64' }

$distName = "perl-$PerlVersion-$Platform"

# A fixed, machine-neutral build directory rather than a random one under
# %TEMP%. MSVC records the absolute path of every header it finds through -I,
# and __FILE__ carries that string into any assertion message -- which matters
# for exactly one binary, lib\auto\re\re.dll, the DEBUGGING build of the regex
# engine. Building under a constant path makes that string identical on every
# builder and free of anything that identifies the machine. It is also short,
# which the Perl tree needs to stay clear of MAX_PATH.
$work = if ($env:PORTABLE_PERL_WORK) { $env:PORTABLE_PERL_WORK } else { 'C:\portable-perl-build' }
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# A fixed, machine-neutral staging prefix.
#
# Windows Perl resolves @INC against the location of perl.exe at runtime, but
# %Config still records whatever prefix it was installed to. Installing to a
# constant path means the value baked into %Config is the same placeholder on
# every builder rather than a CI runner's working directory, and post-processing
# rewrites that one known string.
$prefix = if ($env:PORTABLE_PERL_PREFIX) { $env:PORTABLE_PERL_PREFIX } else { 'C:\portable-perl' }
if (Test-Path $prefix) { Remove-Item -Recurse -Force $prefix }

Write-Log "Building $distName ($toolchain)"

# --- toolchain --------------------------------------------------------------
#
# Both makefiles take the same configuration variables. INST_VER and INST_ARCH
# are left empty so the tree is <prefix>\bin and <prefix>\lib, with the CORE
# headers at <prefix>\lib\CORE. USE_ITHREADS matches the Unix builds. CFG is
# deliberately left unset; setting it selects a debug build.

$commonArgs = @(
    "INST_TOP=$prefix"
    'INST_VER='
    'INST_ARCH='
    'USE_ITHREADS=define'
    'USE_MULTI=define'
    'USE_PERLIO=define'
    'USE_LARGE_FILES=define'
)
$make = $null
$makeArgs = @()
$parallel = @()

if ($toolchain -eq 'msvc') {
    if ($SetupMsvc) {
        Write-Log "Importing the MSVC $msvcArch developer environment"
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path $vswhere)) { Die "vswhere.exe not found at $vswhere" }

        $vsRoot = & $vswhere -latest -products '*' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if (-not $vsRoot) {
            # arm64 images advertise the ARM64 toolset component instead.
            $vsRoot = & $vswhere -latest -products '*' -property installationPath
        }
        if (-not $vsRoot) { Die 'no Visual Studio installation found' }

        $vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvarsall.bat'
        if (-not (Test-Path $vcvars)) { Die "vcvarsall.bat not found at $vcvars" }

        # vcvarsall only exports into the cmd.exe that called it, so run it
        # there and import the environment it leaves behind. This goes through
        # a small batch file rather than `cmd /c "..."`: the vcvarsall path
        # contains spaces and so needs quoting, and PowerShell's legacy argument
        # passing to cmd.exe does not reliably preserve quotes nested inside a
        # quoted /c command.
        $shim = Join-Path $work 'vcvars.cmd'
        $envDump = Join-Path $work 'vcvars-env.txt'
        @(
            '@echo off'
            "call `"$vcvars`" $msvcArch >nul"
            'if errorlevel 1 exit /b 1'
            "set > `"$envDump`""
        ) | Set-Content -Path $shim -Encoding ascii

        & cmd.exe /d /c $shim
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $envDump)) {
            Die "vcvarsall.bat $msvcArch failed (exit $LASTEXITCODE)"
        }
        foreach ($line in Get-Content -Path $envDump) {
            if ($line -match '^([^=]+)=(.*)$') {
                Set-Item -Path ("Env:" + $Matches[1]) -Value $Matches[2] -ErrorAction SilentlyContinue
            }
        }
        if (-not $env:VCToolsInstallDir) {
            Die "vcvarsall.bat $msvcArch ran but did not export VCToolsInstallDir"
        }
        Write-Host "#   VCToolsInstallDir=$env:VCToolsInstallDir"
    }

    if (-not (Get-Command nmake.exe -ErrorAction SilentlyContinue)) {
        Die 'nmake.exe is not on PATH; run from a VS developer prompt or pass -SetupMsvc'
    }

    # Map the compiler version onto a CCTYPE that win32/Makefile understands.
    # The Makefile refuses to build when CCTYPE is unset.
    $clBanner = (& cmd.exe /d /c 'cl 2>&1') -join "`n"
    $cctype = if ($clBanner -match 'Version (\d+)\.(\d+)') {
        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
        if     ($major -eq 19 -and $minor -lt 10) { 'MSVC140' }
        elseif ($major -eq 19 -and $minor -lt 20) { 'MSVC141' }
        elseif ($major -eq 19 -and $minor -lt 30) { 'MSVC142' }
        elseif ($major -eq 19 -and $minor -lt 50) { 'MSVC143' }
        else                                      { 'MSVC145' }
    } else { 'MSVC143' }
    Write-Log "Using CCTYPE=$cctype ($msvcArch)"

    # Optimisation. win32/Makefile defaults to "-O1 -Zi -GL":
    #   -O1  upstream's deliberate choice, not a mistake. The comment in
    #        win32/Makefile notes -O1 produces smaller code that measures
    #        *faster* than -O2 for the interpreter loop on x86 and x64.
    #   -GL  whole-program optimisation (link-time codegen), which we keep.
    #   -Zi  emits debug info and bakes an absolute .pdb path into the binary.
    #        Dropped: it is a debug artifact and a build-host path leak.
    #
    # The link step needs the same treatment. The Makefile's release LINK_DBG
    # is "-debug -opt:ref,icf -ltcg", and -debug makes link.exe write a PDB
    # and record its absolute path in every .exe and .dll -- perl.exe,
    # perl5xx.dll and each XS DLL (MakeMaker inherits the flags through
    # $Config{ldflags}). No PDB ships, so keep only the optimisation flags.
    $make = 'nmake.exe'
    $makeArgs = @(
        "CCTYPE=$cctype"
        'INST_DRV='
        'OPTIMIZE=-O1 -GL'
        'LINK_DBG=-opt:ref,icf -ltcg'
    ) + $commonArgs
}
else {
    if (-not $MingwRoot) {
        $MingwRoot = if ($env:PORTABLE_PERL_MINGW) { $env:PORTABLE_PERL_MINGW } else { 'C:\msys64\ucrt64' }
    }
    $mingwBin = Join-Path $MingwRoot 'bin'
    foreach ($tool in @('gcc.exe', 'g++.exe', 'mingw32-make.exe')) {
        if (-not (Test-Path (Join-Path $mingwBin $tool))) {
            Die "$tool not found in $mingwBin; install mingw-w64-ucrt-x86_64-gcc and mingw-w64-ucrt-x86_64-make, or pass -MingwRoot"
        }
    }

    # The GNUmakefile hardcodes the make it hands to make_ext.pl -- and records
    # in $Config{make} -- as "gmake", the name Strawberry ships it under. MSYS2
    # only provides mingw32-make.exe, so give the build a gmake.exe of its own
    # rather than overriding PLMAKE: that keeps $Config{make} saying "gmake",
    # which is what CPAN tooling on Windows expects to find.
    $tools = Join-Path $work 'tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    Copy-Item (Join-Path $mingwBin 'mingw32-make.exe') (Join-Path $tools 'gmake.exe')

    # Put the chosen toolchain first, and keep two things out of the way:
    # any directory holding sh.exe (GNU make switches to it as its shell if
    # one is on PATH, and the GNUmakefile's recipes are written for cmd.exe),
    # and Strawberry Perl, which CI images preinstall and which carries its
    # own gcc and gmake.
    $kept = @()
    foreach ($dir in ($env:Path -split ';')) {
        if (-not $dir) { continue }
        if ($dir -like '*\Strawberry\*') { continue }
        if (Test-Path (Join-Path $dir 'sh.exe')) { continue }
        $kept += $dir
    }
    $env:Path = (@($tools, $mingwBin) + $kept) -join ';'

    $gccTarget  = (& gcc -dumpmachine).Trim()
    $gccVersion = [version]((& gcc -dumpfullversion).Trim())
    if ($gccTarget -ne 'x86_64-w64-mingw32') { Die "expected an x86_64-w64-mingw32 gcc, got $gccTarget" }

    # The toolchain must target the UCRT: that is what current Strawberry Perl
    # is built against, so XS modules built for it meet the same C runtime
    # here, and it is also the runtime the MSVC flavour uses. mingw-w64 defines
    # _UCRT whenever the default CRT is the UCRT.
    $macros = ('' | & gcc -dM -E -include _mingw.h -) -join "`n"
    if ($macros -notmatch '#define _UCRT') { Die "gcc at $mingwBin does not target the UCRT (use the MSYS2 UCRT64 environment)" }

    # win32/GNUmakefile defaults to -Os because of GH #20081, a GCC bug that
    # made -O2 builds fail on Windows 11. GCC 15.1 fixed it, so -O2 is used
    # from there on and the test suite is what guards against a regression.
    $optimize = if ($gccVersion -ge [version]'15.1') { '-O2' } else {
        Write-Warning "gcc $gccVersion predates the fix for GH #20081; building with -Os"
        '-Os'
    }
    Write-Log "Using gcc $gccVersion ($gccTarget, UCRT), optimize=$optimize"

    $make = 'gmake.exe'
    $makeArgs = @('CCTYPE=GCC', "CCHOME=$MingwRoot", "OPTIMIZE=$optimize") + $commonArgs
    $parallel = @("-j$env:NUMBER_OF_PROCESSORS")
}

# --- fetch and unpack -------------------------------------------------------

$tarball = Join-Path $work "perl-$PerlVersion.tar.gz"
Write-Log "Fetching $($perlSpec.url)"
Invoke-WebRequest -Uri $perlSpec.url -OutFile $tarball -UseBasicParsing

$actual = (Get-FileHash -Path $tarball -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $perlSpec.sha256.ToLower()) {
    Die "checksum mismatch for perl $PerlVersion : expected $($perlSpec.sha256), got $actual"
}

Write-Log 'Unpacking Perl source'
& tar.exe -xzf $tarball -C $work
if ($LASTEXITCODE -ne 0) { Die 'failed to unpack the Perl source' }
$srcDir = Join-Path $work "perl-$PerlVersion"
$win32 = Join-Path $srcDir 'win32'

# --- build ------------------------------------------------------------------

Push-Location $win32
try {
    Write-Log "Compiling ($make)"
    & $make @parallel @makeArgs
    if ($LASTEXITCODE -ne 0) { Die "$make failed" }

    if ($RunTests) {
        # Worth the wall-clock: this is the check that the optimisation settings
        # did not miscompile the interpreter.
        #
        # test-notty rather than test: it sets PERL_SKIP_TTY_TEST, without which
        # op/stat.t asserts that STDIN is a terminal -- which it never is on a
        # CI runner. README.win32 prescribes exactly this for that failure.
        Write-Log 'Running the Perl test suite'
        & $make @makeArgs test-notty
        if ($LASTEXITCODE -ne 0) { Die 'perl test suite failed' }
    }

    Write-Log 'Installing to staging prefix'
    & $make @makeArgs install
    if ($LASTEXITCODE -ne 0) { Die "$make install failed" }
}
finally {
    Pop-Location
}

# --- bundle cpanm -----------------------------------------------------------
#
# Before post-processing, so cpanm's .bat wrapper gets the same treatment as
# the ones installperl created.

Write-Log 'Bundling cpanm'
$cpanmTar = Join-Path $work 'cpanm.tar.gz'
Invoke-WebRequest -Uri $versions.cpanm.url -OutFile $cpanmTar -UseBasicParsing
$cpanmHash = (Get-FileHash -Path $cpanmTar -Algorithm SHA256).Hash.ToLower()
if ($cpanmHash -ne $versions.cpanm.sha256.ToLower()) {
    Die "checksum mismatch for cpanm: expected $($versions.cpanm.sha256), got $cpanmHash"
}
$cpanmDir = Join-Path $work 'cpanm-src'
New-Item -ItemType Directory -Path $cpanmDir -Force | Out-Null
& tar.exe -xzf $cpanmTar -C $cpanmDir --strip-components=1
Copy-Item (Join-Path $cpanmDir 'bin\cpanm') (Join-Path $prefix 'bin\cpanm') -Force

# pl2bat gives it the same .bat wrapper the other utilities get, so `cpanm`
# works from cmd.exe and matches how rules_perl locates tools. installperl
# leaves pl2bat itself as a .bat; perl reads that form directly.
$pl2bat = @('bin\pl2bat.bat', 'bin\pl2bat.pl') |
    ForEach-Object { Join-Path $prefix $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $pl2bat) { Die "pl2bat not found under $prefix\bin" }
& (Join-Path $prefix 'bin\perl.exe') $pl2bat (Join-Path $prefix 'bin\cpanm')
if ($LASTEXITCODE -ne 0) { Die 'pl2bat failed for cpanm' }

# --- post-process -----------------------------------------------------------

& (Join-Path $PSScriptRoot 'postprocess-windows.ps1') `
    -Prefix $prefix -PerlVersion $PerlVersion -Toolchain $toolchain `
    -MsvcArch $msvcArch -MingwRoot $MingwRoot

# --- package ----------------------------------------------------------------

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$staged = Join-Path $work $distName
Move-Item $prefix $staged

$archive = Join-Path $OutDir "$distName.tar.xz"
Write-Log "Creating $archive"
& tar.exe --create --xz --directory $work --file $archive $distName
if ($LASTEXITCODE -ne 0) { Die 'failed to create the archive' }

$sum = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLower()
"$sum  $distName.tar.xz" | Set-Content -Path "$archive.sha256" -Encoding ascii -NoNewline

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Log "Built $archive"
