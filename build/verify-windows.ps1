<#
.SYNOPSIS
    Acceptance-test a built Windows distribution archive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Archive,
    [string]$PerlVersion = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'pe-imports.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PerlVersion) {
    $PerlVersion = (Get-Content (Join-Path $RepoRoot 'versions.json') -Raw | ConvertFrom-Json).default
}

function Write-Log { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

$script:Failures = 0
function Check {
    param([string]$Desc, [bool]$Condition)
    if ($Condition) { Write-Host "ok   - $Desc" }
    else { Write-Host "FAIL - $Desc" -ForegroundColor Red; $script:Failures++ }
}

$Archive = (Resolve-Path $Archive).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("pp-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'a') -Force | Out-Null

Write-Log "Unpacking $Archive"
& tar.exe -xf $Archive -C (Join-Path $work 'a')
if ($LASTEXITCODE -ne 0) { throw 'failed to unpack the archive' }

$root = (Get-ChildItem -Path (Join-Path $work 'a') -Directory | Select-Object -First 1).FullName
$perlExe = Join-Path $root 'bin\perl.exe'
Check 'bin\perl.exe is present' (Test-Path $perlExe)
if (-not (Test-Path $perlExe)) { throw 'no perl.exe in the archive' }

# --- 1. build-host path leakage ---------------------------------------------

Write-Log 'Scanning for build-host paths'
# C:\portable-perl is the fixed staging prefix from build-windows.ps1: it must
# have been rewritten to the ".../" marker form by post-processing. The rest
# are where the CI runners keep things that must not be referenced: the
# checkout, the temp dir, and the Strawberry Perl the images preinstall (a hit
# there would mean the -gnu build picked up Strawberry's gcc instead of the
# MSYS2 one). C:\msys64 is deliberately not listed: $Config{libpth} records
# the compiler's library directories on every platform, and that is toolchain
# location rather than build-host identity.
#
# "\\+" rather than "\\": inside Perl's quoted strings (Config.pm's bootstrap
# hash, for one) every backslash is doubled, and a leak spelled that way must
# be caught just the same.
#
# The staging-prefix pattern ends in a lookahead so that it does not also match
# C:\portable-perl-build, the fixed build directory: that string is present by
# design in lib\auto\re\re.dll (see build-windows.ps1) and names no machine.
$leakPatterns = @('C:\\+hostedtoolcache', 'D:\\+a\\+portable-perl', 'D:\\+a\\+_temp',
                  'AppData\\+Local\\+Temp\\+portable-perl', 'C:\\+portable-perl(?![\w-])',
                  'C:\\+Strawberry')
foreach ($pat in $leakPatterns) {
    # The cap only guards against something pathological; it has to stay above
    # the size of perl5xx.dll, which is where a path compiled in from config.h
    # would end up.
    # @(...) throughout: under Set-StrictMode a pipeline that yields exactly one
    # object has no .Count, and a single hit is the common case for a leak.
    $hits = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -lt 64MB } |
        Select-String -Pattern $pat -List -ErrorAction SilentlyContinue)
    Check "no build-host path matching $pat" ($hits.Count -eq 0)
    foreach ($hit in $hits) {
        # Show what surrounds the match, so a hit inside a binary can be
        # attributed (a __FILE__ in an assertion, a PDB record, ...) without
        # having the artifact to hand.
        $m = $hit.Matches[0]
        $from = [Math]::Max(0, $m.Index - 80)
        $window = $hit.Line.Substring($from, [Math]::Min(240, $hit.Line.Length - $from)) -replace '[^\x20-\x7e]', '.'
        Write-Host "#   $($hit.Path.Substring($root.Length + 1))"
        Write-Host "#     ...$window..."
    }
}

# --- 2. the distribution carries its own runtime ----------------------------
#
# Every PE image in the tree -- perl.exe, perl5xx.dll, the XS DLLs under
# lib\auto and whatever runtime was vendored -- may import only DLLs that are
# part of Windows or that ship in bin\. Anything else would make the artifact
# depend on what happens to be installed on the target.

Write-Log 'Checking DLL imports'
$binDir = Join-Path $root 'bin'
$images = @(Get-ChildItem -Path $root -Recurse -File -Include '*.exe', '*.dll')
Check "found PE images to inspect ($($images.Count))" ($images.Count -gt 0)

$unsatisfied = @{}
foreach ($pe in $images) {
    foreach ($dll in Get-PeImports -Path $pe.FullName) {
        if (Test-WindowsSystemDll $dll) { continue }
        if (Test-Path (Join-Path $binDir $dll)) { continue }
        if (-not $unsatisfied.ContainsKey($dll)) { $unsatisfied[$dll] = @() }
        $unsatisfied[$dll] += $pe.FullName.Substring($root.Length + 1)
    }
}
Check 'every import is a Windows system DLL or ships in bin\' ($unsatisfied.Count -eq 0)
foreach ($dll in ($unsatisfied.Keys | Sort-Object)) {
    Write-Host "#   $dll needed by: $($unsatisfied[$dll] -join ', ')"
}

$vendored = @(Get-ChildItem -Path $binDir -File -Filter '*.dll' | Where-Object { $_.Name -notmatch '^perl\d*\.dll$' })
Write-Host "#   vendored runtime: $(if ($vendored) { ($vendored.Name -join ', ') } else { '(none)' })"

# --- 3. functional smoke test, in place -------------------------------------
#
# First take every other perl off PATH. CI images carry Strawberry Perl, and a
# wrapper that quietly fell back to it (bin\xsubpp.bat is run by name from
# smoke.pl, exactly as rules_perl runs it) would pass here and fail on a clean
# machine. With PATH scrubbed, anything that is not self-contained fails now.

$env:Path = (($env:Path -split ';') | Where-Object {
    $_ -and -not (Test-Path (Join-Path $_ 'perl.exe'))
}) -join ';'
Write-Host "#   PATH scrubbed of other perls: $(if (Get-Command perl.exe -ErrorAction SilentlyContinue) { 'FAILED' } else { 'ok' })"

Write-Log 'Running smoke test in place'
& $perlExe (Join-Path $RepoRoot 'test\smoke.pl') --version $PerlVersion
Check 'smoke test passes in place' ($LASTEXITCODE -eq 0)

# --- 4. the same tree, moved -------------------------------------------------

Write-Log 'Running smoke test after relocation'
$moved = Join-Path $work 'relocated\a\much\deeper\destination'
New-Item -ItemType Directory -Path (Split-Path -Parent $moved) -Force | Out-Null
Move-Item $root $moved

& (Join-Path $moved 'bin\perl.exe') (Join-Path $RepoRoot 'test\smoke.pl') --version $PerlVersion
Check 'smoke test passes after relocation' ($LASTEXITCODE -eq 0)

# --- 5. toolchain contract expected by rules_perl ----------------------------
#
# perl_toolchain accepts bin\<tool>.exe or bin\<tool>.bat; pl2bat produces the
# .bat wrappers during install.

Write-Log 'Checking the rules_perl toolchain contract'
Check 'bin\perl.exe is present' (Test-Path (Join-Path $moved 'bin\perl.exe'))
Check 'an xsubpp wrapper is present' (
    (Test-Path (Join-Path $moved 'bin\xsubpp.bat')) -or (Test-Path (Join-Path $moved 'bin\xsubpp'))
)
Check 'CORE headers are present' (
    @(Get-ChildItem -Path $moved -Recurse -Filter 'perl.h' -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -like '*CORE*' }).Count -gt 0
)
Check 'the import library for XS linking is present' (
    @(Get-ChildItem -Path (Join-Path $moved 'lib\CORE') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(perl\d*\.lib|libperl\d*\.a)$' }).Count -gt 0
)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Failures -gt 0) {
    throw "$($script:Failures) check(s) failed for $Archive"
}
Write-Log "All checks passed for $(Split-Path -Leaf $Archive)"
