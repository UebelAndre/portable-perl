<#
.SYNOPSIS
    Slim down a freshly installed Windows Perl tree and make it self-contained.

.DESCRIPTION
    Unlike the Unix builds there is no @INC rewriting to do: win32.c resolves
    library paths against the directory of the running executable. What this
    script does handle is pruning, removing build-host paths from %Config, and
    vendoring the compiler's runtime DLLs next to perl.exe so the distribution
    does not depend on a redistributable (MSVC) or a MinGW installation (GCC)
    being present on the target.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$PerlVersion,
    [Parameter(Mandatory = $true)][ValidateSet('msvc', 'gnu')][string]$Toolchain,
    [string]$MsvcArch = 'x64',
    [string]$MingwRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'pe-imports.ps1')

function Write-Log { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# --- 0. make the staging tree writable --------------------------------------
#
# installperl marks everything it installs read-only, as make install does on
# Unix. Clear that tree-wide: the %Config rewrite below has to edit files, and
# the archive should extract writable like the Unix flavours do (tar records
# the read-only attribute as a 0444 mode).

Write-Log 'Making the tree writable'
Get-ChildItem -Path $Prefix -Recurse -File -Force |
    Where-Object { $_.IsReadOnly } |
    ForEach-Object { $_.IsReadOnly = $false }

# --- 1. prune ---------------------------------------------------------------

Write-Log 'Pruning'
foreach ($dir in @('html', 'man')) {
    $p = Join-Path $Prefix $dir
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}
$unicoreTest = Join-Path $Prefix 'lib\unicore\TestNorm.pl'
if (Test-Path $unicoreTest) { Remove-Item -Force $unicoreTest }

Get-ChildItem -Path $Prefix -Recurse -File -Include '*.pod', '.packlist', 'perllocal.pod' `
    -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# Debug and incremental-link leftovers. The import library (perl5xx.lib or
# libperl.a) stays: XS modules link against it.
Get-ChildItem -Path $Prefix -Recurse -File -Include '*.pdb', '*.exp', '*.ilk' `
    -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# --- 2. make %Config relocatable --------------------------------------------

& (Join-Path $PSScriptRoot 'relocate-windows-config.ps1') -Prefix $Prefix

# --- 2b. make the bin\ wrappers self-contained ------------------------------
#
# installperl wraps every script in a .bat via ExtUtils::PL2Bat, whose header
# re-invokes the script as `@perl -x -S %0 %*` -- whichever perl is first on
# PATH, which is not necessarily this one and on a clean machine is nothing at
# all. rules_perl runs bin\xsubpp.bat directly as a build action, so the
# wrappers must find the perl.exe beside them: %~dp0 is the batch file's own
# directory. The `eval 'exec <perlpath> -S $0'` prologue inside the scripts is
# dead code (it is guarded by an undefined variable) but names the staging
# prefix, so it gets the same bare "perl" the Unix post-processor uses.

Write-Log 'Making bin\ wrappers self-contained'
# Match the prefix spelled with '\', '\\' or '/'.
$prefixPattern = [regex]::Escape($Prefix.TrimEnd('\')) -replace '\\\\', '[\\/]+'
$wrapperCount = 0
foreach ($bat in Get-ChildItem -Path (Join-Path $Prefix 'bin') -File -Filter '*.bat') {
    $text = Get-Content -LiteralPath $bat.FullName -Raw
    $new = [regex]::Replace($text, '(?m)^@perl (?=-x -S )', '@"%~dp0perl.exe" ')
    $new = [regex]::Replace($new, "$prefixPattern[\\/]+bin[\\/]+perl\.exe", 'perl')
    if ($new -ne $text) {
        Set-Content -LiteralPath $bat.FullName -Value $new -NoNewline
        $wrapperCount++
    }
}
Write-Host "#   rewrote $wrapperCount wrappers"

# --- 3. vendor the compiler runtime -----------------------------------------
#
# Windows resolves a DLL's own imports starting from the directory of the
# executable, so dropping the runtime into bin\ is enough for perl.exe, for
# perl5xx.dll and for every XS DLL under lib\auto. Which files that is depends
# on the toolchain:
#
#   msvc  win32/Makefile hardcodes -MD, so the binaries import vcruntime140.dll
#         (and friends) from the VC++ redistributable. The UCRT itself
#         (api-ms-win-crt-*) ships with Windows 10 and later.
#   gnu   perl is linked through g++, which defaults to the shared libgcc, and
#         MSYS2's libgcc in turn depends on libwinpthread. Both live in the
#         toolchain's bin directory.
#
# Rather than hardcode either list, read the import tables of everything in
# the tree and copy whatever the runtime directory can satisfy, repeating
# until nothing new is imported. verify-windows.ps1 then independently checks
# that every remaining import is a Windows system DLL.

Write-Log 'Vendoring the compiler runtime'
$runtimeDir = $null

if ($Toolchain -eq 'msvc') {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $vsRoot = & $vswhere -latest -products '*' -property installationPath
        if ($vsRoot) {
            $redist = Join-Path $vsRoot 'VC\Redist\MSVC'
            if (Test-Path $redist) {
                # Newest redist version, then its <arch>\Microsoft.VC14x.CRT directory.
                $newest = Get-ChildItem -Path $redist -Directory |
                    Where-Object { $_.Name -match '^\d+\.' } |
                    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
                if ($newest) {
                    $crt = Get-ChildItem -Path (Join-Path $newest.FullName $MsvcArch) -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*.CRT' } | Select-Object -First 1
                    if ($crt) { $runtimeDir = $crt.FullName }
                }
            }
        }
    }
    if (-not $runtimeDir) {
        Write-Warning 'could not locate the VC++ redistributable; relying on verification to catch a missing runtime'
    }
} else {
    if (-not $MingwRoot) { throw '-MingwRoot is required for the gnu toolchain' }
    $runtimeDir = Join-Path $MingwRoot 'bin'
}

$copied = @()
if ($runtimeDir) {
    Write-Host "#   runtime directory: $runtimeDir"
    $copied = @(Copy-RuntimeImports -Root $Prefix -BinDir (Join-Path $Prefix 'bin') -RuntimeDir $runtimeDir)
}

if ($copied.Count -gt 0) {
    Write-Host "#   vendored: $($copied -join ', ')"
} else {
    Write-Host '#   nothing to vendor'
}

Write-Log 'Post-processing complete'
