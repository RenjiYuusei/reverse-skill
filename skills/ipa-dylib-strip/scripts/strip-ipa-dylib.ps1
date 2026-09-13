<#
.SYNOPSIS
    Inspects, strips unwanted dylibs and Mach-O load commands from an iOS IPA, then repacks it.

.DESCRIPTION
    Automates removing third-party injected tweaks/dylibs (e.g., ad injection, custom key systems,
    telemetry tweaks) from modified iOS IPAs while keeping desired frameworks/dylibs intact.
    Handles:
    - Extracting IPA zip container
    - Scanning Mach-O executable load commands (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, etc.)
    - Zeroing out target load commands and updating Mach-O header (ncmds & sizeofcmds)
    - Deleting the dylib files from app bundle / Frameworks
    - Repacking into a clean IPA

.PARAMETER InputIpa
    Path to source .ipa file.

.PARAMETER OutputIpa
    Path to output clean .ipa file. If omitted, defaults to [InputIpa_Name]_stripped.ipa.

.PARAMETER StripDylib
    One or more dylib names or regex patterns to remove (e.g. "deltax", "Baby_roblox.dylib").

.PARAMETER ListOnly
    If set, only lists all dylibs in the app bundle and load commands in the binary without modifying.

.EXAMPLE
    .\strip-ipa-dylib.ps1 -InputIpa "app.ipa" -ListOnly
    .\strip-ipa-dylib.ps1 -InputIpa "app.ipa" -OutputIpa "clean.ipa" -StripDylib "deltax"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputIpa,

    [Parameter(Position = 1)]
    [string]$OutputIpa,

    [Parameter(Position = 2)]
    [string[]]$StripDylib = @(),

    [switch]$ListOnly,
    [switch]$KeepExtracted
)

$ErrorActionPreference = 'Stop'

function Get-U32 {
    param([byte[]]$b, [int]$off)
    return [long]$b[$off] + ([long]$b[$off+1] * 256) + ([long]$b[$off+2] * 65536) + ([long]$b[$off+3] * 16777216)
}

function Set-U32 {
    param([byte[]]$b, [int]$off, [long]$val)
    $b[$off]   = [byte]($val -band 0xFF)
    $b[$off+1] = [byte](($val -shr 8) -band 0xFF)
    $b[$off+2] = [byte](($val -shr 16) -band 0xFF)
    $b[$off+3] = [byte](($val -shr 24) -band 0xFF)
}

if (-not (Test-Path -LiteralPath $InputIpa)) {
    throw "Input IPA file not found: $InputIpa"
}

$inputFullPath = (Resolve-Path -LiteralPath $InputIpa).Path
$inputDir = Split-Path -Parent $inputFullPath
$inputBase = [System.IO.Path]::GetFileNameWithoutExtension($inputFullPath)

if (-not $OutputIpa) {
    $OutputIpa = Join-Path $inputDir "${inputBase}_stripped.ipa"
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ipa_strip_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    Write-Host "[*] Extracting IPA: $inputFullPath" -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($inputFullPath, $tempDir)

    $payloadDir = Join-Path $tempDir "Payload"
    if (-not (Test-Path $payloadDir)) {
        throw "Invalid IPA structure: Payload directory missing."
    }

    $appDirItem = Get-ChildItem $payloadDir -Directory | Select-Object -First 1
    if (-not $appDirItem) {
        throw "No .app bundle found inside Payload."
    }
    $appPath = $appDirItem.FullName
    Write-Host "[+] Found App Bundle: $($appDirItem.Name)" -ForegroundColor Green

    # Detect main binary
    $infoPlistPath = Join-Path $appPath "Info.plist"
    $executableName = $null
    if (Test-Path $infoPlistPath) {
        $plistBytes = [System.IO.File]::ReadAllBytes($infoPlistPath)
        $plistText = [System.Text.Encoding]::UTF8.GetString($plistBytes)
        if ($plistText -match '<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>') {
            $executableName = $Matches[1].Trim()
        }
    }

    if ($executableName -and (Test-Path (Join-Path $appPath $executableName))) {
        $binPath = Join-Path $appPath $executableName
    } else {
        # Fallback: largest executable file
        $binFile = Get-ChildItem $appPath -File | Where-Object { $_.Length -gt 500KB } | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $binFile) {
            throw "Unable to find main Mach-O executable in $appPath"
        }
        $binPath = $binFile.FullName
    }

    Write-Host "[+] Main Executable: $(Split-Path -Leaf $binPath)" -ForegroundColor Green

    # Scan dylibs inside app bundle
    $bundleDylibs = Get-ChildItem $appPath -Filter "*.dylib" -Recurse
    Write-Host "`n[*] Dylibs present in app bundle:" -ForegroundColor Yellow
    foreach ($d in $bundleDylibs) {
        $rel = $d.FullName.Substring($appPath.Length + 1)
        Write-Host "    - $rel ($([Math]::Round($d.Length / 1KB, 1)) KB)"
    }

    # Parse Mach-O binary
    Write-Host "`n[*] Parsing Mach-O load commands from executable..." -ForegroundColor Cyan
    $binBytes = [System.IO.File]::ReadAllBytes($binPath)
    $magic = Get-U32 $binBytes 0

    $is64 = ($magic -eq [long]0xFEEDFACFL)
    $is32 = ($magic -eq [long]0xFEEDFACEL)
    if (-not ($is64 -or $is32)) {
        throw "Unsupported binary format or magic: 0x$($magic.ToString('X8'))"
    }

    $hdrSize = if ($is64) { 32 } else { 28 }
    $ncmds = Get-U32 $binBytes 0x10
    $sizeofcmds = Get-U32 $binBytes 0x14

    Write-Host "    Mach-O: $(if ($is64){'64-bit'}else{'32-bit'}), Total Commands: $ncmds, SizeOfCmds: 0x$($sizeofcmds.ToString('X'))"

    $cmdOffset = $hdrSize
    $loadCommands = @()

    for ($i = 0; $i -lt $ncmds; $i++) {
        if ($cmdOffset + 8 -ge $binBytes.Length) { break }
        $cmdType = Get-U32 $binBytes $cmdOffset
        $cmdSize = Get-U32 $binBytes ($cmdOffset + 4)
        if ($cmdSize -lt 8 -or $cmdSize -gt 65536) { break }

        $rawType = $cmdType -band 0x0FFFFFFF
        # 0xC = LC_LOAD_DYLIB, 0x18 = LC_LOAD_WEAK_DYLIB, 0x1F = LC_REEXPORT_DYLIB, 0x20 = LC_LAZY_LOAD_DYLIB
        if ($rawType -in 0xC, 0x18, 0x1F, 0x20) {
            $nameRelOff = Get-U32 $binBytes ($cmdOffset + 8)
            $nameAbsOff = $cmdOffset + $nameRelOff
            $sb = [System.Text.StringBuilder]::new()
            $p = $nameAbsOff
            while ($p -lt $binBytes.Length -and $binBytes[$p] -ne 0 -and ($p - $nameAbsOff) -lt 300) {
                [void]$sb.Append([char]$binBytes[$p])
                $p++
            }
            $dylibName = $sb.ToString()
            $typeName = switch ($rawType) {
                0x0C { "LC_LOAD_DYLIB" }
                0x18 { "LC_LOAD_WEAK_DYLIB" }
                0x1F { "LC_REEXPORT_DYLIB" }
                0x20 { "LC_LAZY_LOAD_DYLIB" }
            }
            $loadCommands += [PSCustomObject]@{
                Index      = $i
                Offset     = $cmdOffset
                Size       = $cmdSize
                Type       = $typeName
                RawType    = $cmdType
                DylibPath  = $dylibName
            }
        }
        $cmdOffset += $cmdSize
    }

    Write-Host "[*] Found $($loadCommands.Count) dylib load commands in Mach-O:" -ForegroundColor Yellow
    foreach ($lc in $loadCommands) {
        Write-Host "    [$($lc.Index)] $($lc.Type) @ 0x$($lc.Offset.ToString('X4')) (size $($lc.Size)): $($lc.DylibPath)"
    }

    if ($ListOnly) {
        Write-Host "`n[+] ListOnly mode complete. No modifications made." -ForegroundColor Green
        return
    }

    if ($StripDylib.Count -eq 0) {
        Write-Host "`n[!] No dylibs specified to strip (-StripDylib). Use -ListOnly or provide target names." -ForegroundColor Yellow
        return
    }

    # Strip matching load commands from binary
    $patchCount = 0
    $bytesToRemoveFromCmds = 0

    foreach ($lc in $loadCommands) {
        $shouldStrip = $false
        foreach ($pattern in $StripDylib) {
            if ($lc.DylibPath -like "*$pattern*" -or $lc.DylibPath -match $pattern) {
                $shouldStrip = $true
                break
            }
        }

        if ($shouldStrip) {
            Write-Host "`n[-] Stripping Mach-O load command for: $($lc.DylibPath)" -ForegroundColor Red
            Write-Host "    Offset: 0x$($lc.Offset.ToString('X4')), Size: $($lc.Size) bytes"
            
            # Zero out the entire load command
            for ($z = 0; $z -lt $lc.Size; $z++) {
                $binBytes[$lc.Offset + $z] = 0
            }
            $patchCount++
            $bytesToRemoveFromCmds += $lc.Size
        }
    }

    if ($patchCount -gt 0) {
        $newNcmds = $ncmds - $patchCount
        $newSizeofcmds = $sizeofcmds - $bytesToRemoveFromCmds
        Set-U32 $binBytes 0x10 $newNcmds
        Set-U32 $binBytes 0x14 $newSizeofcmds

        [System.IO.File]::WriteAllBytes($binPath, $binBytes)
        Write-Host "[+] Successfully patched binary: decremented ncmds to $newNcmds, sizeofcmds to 0x$($newSizeofcmds.ToString('X'))" -ForegroundColor Green
    } else {
        Write-Host "[!] No matching Mach-O load commands found for given pattern(s)." -ForegroundColor Yellow
    }

    # Delete matching files from app bundle
    $deletedFiles = 0
    foreach ($d in $bundleDylibs) {
        $shouldDelete = $false
        foreach ($pattern in $StripDylib) {
            if ($d.Name -like "*$pattern*" -or $d.FullName -like "*$pattern*" -or $d.Name -match $pattern) {
                $shouldDelete = $true
                break
            }
        }
        if ($shouldDelete) {
            Write-Host "[-] Deleting dylib file: $($d.FullName)" -ForegroundColor Red
            Remove-Item -LiteralPath $d.FullName -Force
            $deletedFiles++
        }
    }
    Write-Host "[+] Deleted $deletedFiles dylib file(s) from app bundle." -ForegroundColor Green

    # Repack to clean IPA
    Write-Host "`n[*] Repacking to clean IPA: $OutputIpa" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $OutputIpa) {
        Remove-Item -LiteralPath $OutputIpa -Force
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $OutputIpa)

    $outSize = (Get-Item -LiteralPath $OutputIpa).Length
    Write-Host "[+] Repack complete: $OutputIpa ($([Math]::Round($outSize / 1MB, 2)) MB)" -ForegroundColor Green

} finally {
    if (-not $KeepExtracted -and (Test-Path $tempDir)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
