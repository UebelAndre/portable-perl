# Dot-sourced by postprocess-windows.ps1 and verify-windows.ps1.
#
# Reads the import table of a PE image without any external tool. dumpbin only
# exists inside a Visual Studio developer environment and objdump only inside
# MSYS2, and neither is on PATH in the step that verifies an archive -- but the
# question "which DLLs does this binary load?" has to be answerable there, for
# both toolchains, and on a developer machine. The format is stable and small
# enough that parsing it directly is less fragile than finding a tool.

function Get-PeImports {
    <#
    .SYNOPSIS
        Return the lower-cased names of every DLL a PE image imports, including
        delay-loaded ones. Returns nothing for a file that is not a PE image.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return @() }

    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -le 0 -or $pe + 24 -gt $bytes.Length) { return @() }
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x00004550) { return @() }   # "PE\0\0"

    $numSections = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optSize     = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $opt         = $pe + 24
    if ($numSections -eq 0 -or $optSize -eq 0) { return @() }

    # The data directories sit at a magic-dependent offset in the optional header.
    $magic = [BitConverter]::ToUInt16($bytes, $opt)
    $dirs = switch ($magic) {
        0x20B { $opt + 112 }   # PE32+
        0x10B { $opt + 96 }    # PE32
        default { return @() }
    }
    $numDirs = [BitConverter]::ToUInt32($bytes, $dirs - 4)

    # Section table, for translating RVAs into file offsets.
    $sections = @()
    $secBase = $opt + $optSize
    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secBase + 40 * $i
        if ($s + 40 -gt $bytes.Length) { break }
        $sections += [pscustomobject]@{
            VirtualSize    = [BitConverter]::ToUInt32($bytes, $s + 8)
            VirtualAddress = [BitConverter]::ToUInt32($bytes, $s + 12)
            RawSize        = [BitConverter]::ToUInt32($bytes, $s + 16)
            RawPointer     = [BitConverter]::ToUInt32($bytes, $s + 20)
        }
    }

    $rvaToOffset = {
        param([uint32]$rva)
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VirtualSize, $s.RawSize)
            if ($rva -ge $s.VirtualAddress -and $rva -lt $s.VirtualAddress + $span) {
                return [int64]$s.RawPointer + ($rva - $s.VirtualAddress)
            }
        }
        return -1
    }
    $readString = {
        param([int64]$offset)
        $end = $offset
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        return [System.Text.Encoding]::ASCII.GetString($bytes, $offset, $end - $offset)
    }

    $names = New-Object System.Collections.Generic.List[string]

    # Directory 1: import table. 20-byte IMAGE_IMPORT_DESCRIPTORs, terminated by
    # an all-zero entry; the DLL name RVA is at +12.
    if ($numDirs -gt 1) {
        $rva = [BitConverter]::ToUInt32($bytes, $dirs + 8 * 1)
        $off = if ($rva) { & $rvaToOffset $rva } else { -1 }
        while ($off -ge 0 -and $off + 20 -le $bytes.Length) {
            $nameRva  = [BitConverter]::ToUInt32($bytes, $off + 12)
            $thunkRva = [BitConverter]::ToUInt32($bytes, $off + 16)
            if ($nameRva -eq 0 -and $thunkRva -eq 0) { break }
            $nameOff = & $rvaToOffset $nameRva
            if ($nameOff -ge 0) { $names.Add((& $readString $nameOff)) }
            $off += 20
        }
    }

    # Directory 13: delay-load imports. 32-byte IMAGE_DELAYLOAD_DESCRIPTORs,
    # terminated by an all-zero entry; the DLL name RVA is at +4. The MSVC build
    # delay-loads ws2_32.dll, so leaving these out would under-report.
    if ($numDirs -gt 13) {
        $rva = [BitConverter]::ToUInt32($bytes, $dirs + 8 * 13)
        $off = if ($rva) { & $rvaToOffset $rva } else { -1 }
        while ($off -ge 0 -and $off + 32 -le $bytes.Length) {
            $nameRva = [BitConverter]::ToUInt32($bytes, $off + 4)
            if ($nameRva -eq 0) { break }
            $nameOff = & $rvaToOffset $nameRva
            if ($nameOff -ge 0) { $names.Add((& $readString $nameOff)) }
            $off += 32
        }
    }

    return @($names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
}

function Copy-RuntimeImports {
    <#
    .SYNOPSIS
        Vendor a toolchain's runtime into a distribution.

    .DESCRIPTION
        Reads the import tables of every PE image under -Root and copies each
        imported DLL that is neither part of Windows nor already in -BinDir
        from -RuntimeDir into -BinDir, repeating for the freshly copied DLLs
        until nothing new is needed. Returns the names copied.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$BinDir,
        [Parameter(Mandatory = $true)][string]$RuntimeDir
    )

    $copied = @()
    $queue = @(Get-ChildItem -Path $Root -Recurse -File -Include '*.exe', '*.dll')
    while ($queue.Count -gt 0) {
        $next = @()
        foreach ($pe in $queue) {
            foreach ($dll in Get-PeImports -Path $pe.FullName) {
                if (Test-WindowsSystemDll $dll) { continue }
                if (Test-Path (Join-Path $BinDir $dll)) { continue }   # already shipped
                $src = Join-Path $RuntimeDir $dll
                if (-not (Test-Path $src)) { continue }               # not the runtime's to provide
                Copy-Item $src $BinDir -Force
                $copied += $dll
                $next += Get-Item (Join-Path $BinDir $dll)
            }
        }
        $queue = $next
    }
    return $copied
}

function Test-WindowsSystemDll {
    <#
    .SYNOPSIS
        True for DLLs that are part of Windows itself and so need not ship.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $n = $Name.ToLowerInvariant()
    # The UCRT and the Windows API sets are exposed through these forwarders on
    # Windows 10 and later, which is the floor for this distribution.
    if ($n -like 'api-ms-win-*' -or $n -like 'ext-ms-win-*') { return $true }
    return $n -in @(
        'kernel32.dll', 'kernelbase.dll', 'ntdll.dll', 'user32.dll', 'gdi32.dll',
        'advapi32.dll', 'shell32.dll', 'shlwapi.dll', 'ole32.dll', 'oleaut32.dll',
        'rpcrt4.dll', 'ws2_32.dll', 'wsock32.dll', 'mswsock.dll', 'iphlpapi.dll',
        'netapi32.dll', 'mpr.dll', 'version.dll', 'winmm.dll', 'comctl32.dll',
        'comdlg32.dll', 'winspool.drv', 'odbc32.dll', 'odbccp32.dll', 'crypt32.dll',
        'bcrypt.dll', 'secur32.dll', 'userenv.dll', 'psapi.dll', 'dbghelp.dll',
        'imagehlp.dll', 'uuid.dll', 'msvcrt.dll', 'ucrtbase.dll',
        # Networking and system-configuration DLLs that core XS modules such
        # as Win32 and Win32API::File import.
        'winhttp.dll', 'wininet.dll', 'dnsapi.dll', 'wldap32.dll', 'setupapi.dll',
        'cfgmgr32.dll', 'wtsapi32.dll', 'powrprof.dll', 'ncrypt.dll'
    )
}
