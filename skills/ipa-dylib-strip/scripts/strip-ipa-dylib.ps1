<#
.SYNOPSIS
    Inspects, strips unwanted dylibs and Mach-O load commands from an iOS IPA, then repacks it.

.DESCRIPTION
    Automates removing third-party injected tweaks/dylibs (e.g., ad injection, custom key systems,
    telemetry tweaks) from modified iOS IPAs while keeping desired frameworks/dylibs intact.
    Handles:
    - Downloading IPA directly from distribution URL or web page (e.g., appinstall.cloud)
    - Extracting IPA zip container
    - Scanning Mach-O executable load commands (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, etc.)
    - Shifting load commands and updating Mach-O header (ncmds & sizeofcmds) cleanly
    - Deleting the dylib files from app bundle / Frameworks
    - Dedicated preset support (e.g. -Preset phong-roblox for stripping Phong Roblox getkey layer)
    - Repacking into a clean IPA

.PARAMETER InputIpa
    Path to source .ipa file. Optional if -Url is provided.

.PARAMETER OutputIpa
    Path to output clean .ipa file. If omitted, defaults to [InputIpa_Name]_stripped.ipa.

.PARAMETER StripDylib
    One or more dylib names or regex patterns to remove (e.g. "deltax", "Baby_roblox.dylib").

.PARAMETER Preset
    Pre-configured target profiles:
    - "phong-roblox": Automatically targets deltax / BabyRoblox getkey layer while preserving Delta core (libgloop.dylib).

.PARAMETER Url
    URL to direct .ipa or appinstall install page to download and process automatically.

.PARAMETER ListOnly
    If set, only lists all dylibs in the app bundle and load commands in the binary without modifying.

.PARAMETER KeepExtracted
    Preserves the extracted bundle directory for manual inspection.

.EXAMPLE
    .\strip-ipa-dylib.ps1 -InputIpa "app.ipa" -ListOnly
    .\strip-ipa-dylib.ps1 -InputIpa "phongroblox.ipa" -Preset phong-roblox
    .\strip-ipa-dylib.ps1 -Url "https://appinstall.cloud/install/ivjudmr50000" -Preset phong-roblox
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputIpa,

    [Parameter(Position = 1)]
    [string]$OutputIpa,

    [Parameter(Position = 2)]
    [string[]]$StripDylib = @(),

    [Parameter()]
    [ValidateSet("phong-roblox", "none")]
    [string]$Preset,

    [Parameter()]
    [string]$Url,

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

# Handle URL download if provided
$downloadedTempIpa = $null
if ($Url) {
    Write-Host "[*] Resolving IPA from URL: $Url" -ForegroundColor Cyan
    $directIpaUrl = $null

    if ($Url -like "*.ipa*" -or $Url -like "*/ios-file/*") {
        $directIpaUrl = $Url
    } else {
        # Fetch page HTML and look for direct download or itms manifest
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)")
            $html = $webClient.DownloadString($Url)
            
            if ($html -match 'href="([^"]+/ios-file/[^"]+\.ipa)"') {
                $directIpaUrl = $Matches[1]
            } elseif ($html -match 'itms-services://\?action=download-manifest&amp;url=([^"&\s]+)') {
                $plistUrl = [System.Uri]::UnescapeDataString($Matches[1])
                $plistContent = $webClient.DownloadString($plistUrl)
                if ($plistContent -match '<string>(https?://[^<]+\.ipa)</string>') {
                    $directIpaUrl = $Matches[1]
                }
            }
        } catch {
            Write-Warning "Failed to parse URL page: $_"
        }
    }

    if (-not $directIpaUrl) {
        throw "Could not resolve direct .ipa download link from $Url"
    }

    Write-Host "[+] Found direct IPA URL: $directIpaUrl" -ForegroundColor Green
    $downloadedTempIpa = Join-Path ([System.IO.Path]::GetTempPath()) ("download_" + [System.Guid]::NewGuid().ToString('N') + ".ipa")
    Write-Host "[*] Downloading IPA..." -ForegroundColor Cyan
    
    Invoke-WebRequest -Uri $directIpaUrl -OutFile $downloadedTempIpa -UserAgent "Mozilla/5.0"
    $InputIpa = $downloadedTempIpa
}

if (-not $InputIpa) {
    throw "Please specify -InputIpa or -Url."
}

if (-not (Test-Path -LiteralPath $InputIpa)) {
    throw "Input IPA file not found: $InputIpa"
}

$inputFullPath = (Resolve-Path -LiteralPath $InputIpa).Path
$inputDir = Split-Path -Parent $inputFullPath
$inputBase = [System.IO.Path]::GetFileNameWithoutExtension($inputFullPath)

# Handle Presets
$activePatterns = [System.Collections.Generic.List[string]]::new()
if ($StripDylib) {
    foreach ($p in $StripDylib) { $activePatterns.Add($p) }
}

if ($Preset -eq "phong-roblox") {
    Write-Host "[*] Applying Preset: phong-roblox (Stripping Phong Roblox getkey layer, preserving Delta core)" -ForegroundColor Magenta
    if (-not ($activePatterns -contains "deltax")) { $activePatterns.Add("deltax") }
    if (-not ($activePatterns -contains "Baby_roblox")) { $activePatterns.Add("Baby_roblox") }
    if (-not ($activePatterns -contains "BabyRoblox")) { $activePatterns.Add("BabyRoblox") }
}

if (-not $OutputIpa) {
    $outDir = if ($downloadedTempIpa) { (Get-Location).Path } else { $inputDir }
    $suffix = if ($Preset -eq "phong-roblox") { "_delta_clean.ipa" } else { "_stripped.ipa" }
    $OutputIpa = Join-Path $outDir "${inputBase}${suffix}"
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

    # Auto-detection of Phong Roblox tweak layer if preset not explicitly passed
    if (-not $Preset -and ($activePatterns.Count -eq 0)) {
        $hasDeltax = $bundleDylibs | Where-Object { $_.Name -like "*deltax*" -or $_.Name -like "*Baby_roblox*" }
        if ($hasDeltax) {
            Write-Host "`n[!] Notice: Detected Phong Roblox injected layer ($($hasDeltax.Name)). Use '-Preset phong-roblox' to auto-strip." -ForegroundColor Yellow
        }
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

    if ($activePatterns.Count -eq 0) {
        Write-Host "`n[!] No dylibs specified to strip. Provide -StripDylib or -Preset phong-roblox." -ForegroundColor Yellow
        return
    }

    # Protected system & critical framework safelist
    $safeList = @("libgloop.dylib", "libswift", "RobloxLib", "Persona2", "Reaper", "libobjc", "libSystem")

    # Strip matching load commands from binary with proper memory shifting
    $patchCount = 0
    $bytesToRemoveFromCmds = 0

    # Sort load commands descending by offset so shifting doesn't invalidate lower offsets
    $cmdsToStrip = @()
    foreach ($lc in $loadCommands) {
        $shouldStrip = $false
        foreach ($pattern in $activePatterns) {
            if ($lc.DylibPath -like "*$pattern*" -or $lc.DylibPath -match $pattern) {
                $isSafe = $false
                foreach ($safe in $safeList) {
                    if ($lc.DylibPath -like "*$safe*" -and $pattern -notlike "*$safe*") {
                        $isSafe = $true
                        break
                    }
                }
                if (-not $isSafe) {
                    $shouldStrip = $true
                    break
                }
            }
        }
        if ($shouldStrip) {
            $cmdsToStrip += $lc
        }
    }

    if ($cmdsToStrip.Count -gt 0) {
        # Process from highest offset to lowest
        $cmdsToStripSorted = $cmdsToStrip | Sort-Object Offset -Descending
        foreach ($lc in $cmdsToStripSorted) {
            Write-Host "`n[-] Stripping Mach-O load command: $($lc.DylibPath)" -ForegroundColor Red
            Write-Host "    Offset: 0x$($lc.Offset.ToString('X4')), Size: $($lc.Size) bytes"

            $cmdEnd = $lc.Offset + $lc.Size
            $totalCmdsEnd = $hdrSize + $sizeofcmds

            # Shift remaining commands left if not at the very end
            $bytesToShift = $totalCmdsEnd - $cmdEnd
            if ($bytesToShift -gt 0) {
                [System.Array]::Copy($binBytes, $cmdEnd, $binBytes, $lc.Offset, $bytesToShift)
            }

            # Zero out the freed tail region
            $freedTailOffset = $totalCmdsEnd - $lc.Size
            for ($z = 0; $z -lt $lc.Size; $z++) {
                $binBytes[$freedTailOffset + $z] = 0
            }

            $sizeofcmds -= $lc.Size
            $ncmds -= 1
            $patchCount++
        }

        Set-U32 $binBytes 0x10 $ncmds
        Set-U32 $binBytes 0x14 $sizeofcmds
        [System.IO.File]::WriteAllBytes($binPath, $binBytes)
        Write-Host "[+] Successfully patched Mach-O: updated ncmds=$ncmds, sizeofcmds=0x$($sizeofcmds.ToString('X'))" -ForegroundColor Green
    } else {
        Write-Host "[!] No matching Mach-O load commands found for given pattern(s)." -ForegroundColor Yellow
    }

    # Delete matching dylib files from app bundle
    $deletedFiles = 0
    foreach ($d in $bundleDylibs) {
        $shouldDelete = $false
        foreach ($pattern in $activePatterns) {
            if ($d.Name -like "*$pattern*" -or $d.FullName -like "*$pattern*" -or $d.Name -match $pattern) {
                $isSafe = $false
                foreach ($safe in $safeList) {
                    if ($d.Name -like "*$safe*" -and $pattern -notlike "*$safe*") {
                        $isSafe = $true
                        break
                    }
                }
                if (-not $isSafe) {
                    $shouldDelete = $true
                    break
                }
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
    if ($downloadedTempIpa -and (Test-Path -LiteralPath $downloadedTempIpa)) {
        Remove-Item -LiteralPath $downloadedTempIpa -Force -ErrorAction SilentlyContinue
    }
}
