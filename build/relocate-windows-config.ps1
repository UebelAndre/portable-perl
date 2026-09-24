<#
.SYNOPSIS
    Make a Windows Perl tree's %Config relocatable.

.DESCRIPTION
    Split out of postprocess-windows.ps1 so it can be exercised on its own,
    against a synthetic tree, without a Windows machine or a full Perl build.

.PARAMETER Prefix
    Where the installed tree actually lives right now.

.PARAMETER RecordedPrefix
    The prefix string baked into the tree's files, which is what gets rewritten
    to the ".../" marker form. On a real build this is the same as -Prefix and
    can be omitted. They differ only when exercising the script off Windows,
    where a tree recording 'C:\portable-perl' sits at some POSIX path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [string]$RecordedPrefix = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Log { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }

# installperl leaves the tree read-only; postprocess-windows.ps1 clears that
# first, but this script is also run on its own, so cope with it here too.
function Set-FileText {
    param([string]$Path, [string]$Text)
    $item = Get-Item -LiteralPath $Path
    if ($item.IsReadOnly) { $item.IsReadOnly = $false }
    Set-Content -LiteralPath $Path -Value $Text -NoNewline
}

# --- make %Config relocatable --------------------------------------------
#
# @INC needs no help on Windows -- win32.c derives it from GetModuleFileNameW.
# %Config is a different matter: Configure records the staging prefix
# literally, and Windows has no -Duserelocatableinc, so without intervention
# $Config{privlib} and friends would point at the machine that built the
# artifact. Things that matter do read them; xsubpp resolves the standard
# typemap under $Config{privlib}, for one.
#
# So do on Windows what -Duserelocatableinc does on Unix: store paths with a
# leading ".../" marker and expand it at runtime against the directory holding
# perl.exe. The relocate_inc() below is upstream's, from the relocatable Unix
# builds, with separator normalisation added because $^X arrives with
# backslashes here.

$relocateSub = @'

sub relocate_inc {
  my $libdir = shift;
  return $libdir unless $libdir =~ s!^\.\.\./!!;
  # Unlike the Unix original, $^X may use either separator on Windows.
  (my $prefix = $^X) =~ s!\\!/!g;
  if ($prefix =~ s!/[^/]*$!!) {
    while ($libdir =~ m!^\.\./!) {
      last unless $prefix =~ s!/([^/]+)$!!;
      if ($1 eq '.' or $1 eq '..') {
        $prefix = "$prefix/$1";
        last;
      }
      substr ($libdir, 0, 3, '');
    }
    $libdir = "$prefix/$libdir";
  }
  $libdir;
}

'@

# The set postprocess-unix.sh uses -- upstream's own list covers only the *exp
# and install* spellings, which would leave $Config{prefix} as a literal
# ".../.." -- plus the man and html keys, which the Unix builds configure to
# "none" but win32/config.vc places under the prefix.
$relocatedKeys = @(
    'archlib', 'archlibexp', 'bin', 'binexp', 'initialinstalllocation',
    'installarchlib', 'installbin', 'installhtmldir', 'installhtmlhelpdir',
    'installman1dir', 'installman3dir', 'installprefix', 'installprefixexp',
    'installprivlib', 'installscript', 'installsitearch', 'installsitebin',
    'installsitelib', 'installsitescript', 'man1dir', 'man1direxp', 'man3dir',
    'man3direxp', 'perlpath', 'prefix', 'prefixexp', 'privlib', 'privlibexp',
    'scriptdir', 'scriptdirexp', 'sitearch', 'sitearchexp', 'sitebin',
    'sitebinexp', 'sitelib', 'sitelib_stem', 'sitelibexp', 'siteprefix',
    'siteprefixexp', 'sitescript', 'sitescriptexp', 'startperl'
) -join ' '

if (-not $RecordedPrefix) { $RecordedPrefix = $Prefix }
$normalizedPrefix = $RecordedPrefix.TrimEnd('\')
# Three spellings occur. Configure writes some values with forward slashes,
# the nmake rules write others with backslashes, and configpm doubles every
# backslash when it quotes the bootstrap hash in Config.pm
# ("scriptdir => 'C:\\portable-perl\\bin'").
$variants = @(
    $normalizedPrefix
    $normalizedPrefix.Replace('\', '/')
    $normalizedPrefix.Replace('\', '\\')
)

function Convert-Prefix {
    param([string]$Text, [string[]]$Variants, [string]$Interpreter)

    $alternatives = ($Variants | ForEach-Object { [regex]::Escape($_) }) -join '|'
    # Consume whatever path follows the prefix as well, so its separators can be
    # normalised: relocate_inc splits on '/' only.
    $tail = '(?<rest>[^\s";,)'']*)'

    return [regex]::Replace($Text, "(?:$alternatives)$tail", {
        param($m)
        # A run of backslashes is one separator: single in most files, doubled
        # inside Config.pm's quoted strings.
        $rest = $m.Groups['rest'].Value -replace '\\+', '/'
        # The interpreter itself collapses to ".../perl.exe" rather than
        # ".../../bin/perl.exe".
        if ($rest -eq '/bin/perl.exe') { return $Interpreter }
        return '.../..' + $rest
    })
}

# The link flags carry the staging prefix too: win32/Makefile passes
# -libpath:"<prefix>\lib\CORE" (the GNUmakefile: -L"...") so the core build can
# find the import library, and that ends up in $Config{ldflags}, lddlflags and
# ldflags_nolargefiles. relocate_inc() only expands a value that *starts* with
# the marker, and ldflags_nolargefiles lives in the part of Config_heavy.pl
# that the relocation loop never sees, so the token is removed instead. Nothing
# needs it afterwards: MakeMaker on Win32 links XS against $(PERL_ARCHIVE),
# the import library by full path, and rules_perl assembles its own link line.
function Remove-PrefixLibpath {
    param([string]$Text)
    # The quotes are plain by the time the value reaches config.sh, but accept
    # the backslash-escaped spelling from the makefile command line as well.
    return [regex]::Replace($Text, '\s*-(?:libpath:|L)\\?"\.\.\./[^"]*"', '')
}

Write-Log 'Rewriting build paths in %Config'

# Config_heavy.pl: rewrite the embedded config_sh text, then add the expansion
# loop just before perl measures it.
$libDir = Join-Path $Prefix 'lib'
$heavy = Join-Path $libDir 'Config_heavy.pl'
if (-not (Test-Path $heavy)) { throw "Config_heavy.pl not found at $heavy" }

$text = Remove-PrefixLibpath (Convert-Prefix (Get-Content -Path $heavy -Raw) $variants '.../perl.exe')
$anchor = 'my $config_sh_len = length $_;'
if (-not $text.Contains($anchor)) {
    throw "could not find the config_sh length anchor in $heavy"
}
$loop = @"
foreach my `$what (qw($relocatedKeys)) {
    s/^(`$what=)(['`"])(#!)?(.*?)\2/`$1 . `$2 . (`$3 || "") . relocate_inc(`$4) . `$2/me;
}
$anchor
"@
$text = $text.Replace($anchor, $loop)
Set-FileText -Path $heavy -Text $text
Write-Host "#   rewrote $heavy"

# Config.pm: it carries relocate_inc for Config_heavy.pl to call, plus a small
# bootstrap hash of its own whose values shadow the heavy file.
$configPm = Join-Path $libDir 'Config.pm'
if (-not (Test-Path $configPm)) { throw "Config.pm not found at $configPm" }

$text = Convert-Prefix (Get-Content -Path $configPm -Raw) $variants '.../perl.exe'
$tie = "tie %Config, 'Config', {"
if (-not $text.Contains($tie)) { throw "could not find the tie block in $configPm" }
$text = $text.Replace($tie, ($relocateSub + $tie))
# Config.pm is written by a Windows perl and so has CRLF line endings; in .NET
# a multiline "$" matches only before "\n", so the anchor has to allow the "\r".
$text = [regex]::Replace($text, "(?m)^(\s+\w+ => )'(\.\.\./[^']*)',(?=\r?$)", "`$1relocate_inc('`$2'),")
Set-FileText -Path $configPm -Text $text
Write-Host "#   rewrote $configPm"

# CORE/config.h holds the same paths as C string literals. Windows never uses
# them to find libraries (win32.c overrides that), but they must not name the
# build host, so the marker form goes in here too.
foreach ($header in @(Get-ChildItem -Path $libDir -Recurse -File `
        -Filter 'config.h' -ErrorAction SilentlyContinue)) {
    $text = Convert-Prefix (Get-Content -Path $header.FullName -Raw) $variants '.../perl.exe'
    Set-FileText -Path $header.FullName -Text $text
    Write-Host "#   rewrote $($header.FullName)"
}
