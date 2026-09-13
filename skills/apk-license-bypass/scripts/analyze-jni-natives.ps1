#Requires -Version 5.1
<#
.SYNOPSIS
    Analyzes an ARM64 ELF (.so) file to map dynamic JNI method registrations (RegisterNatives)
    via .rela.dyn relocation entries and string lookups.
.PARAMETER SoPath
    Path to the ARM64 .so file.
.EXAMPLE
    pwsh -File skills/apk-license-bypass/scripts/analyze-jni-natives.ps1 -SoPath "app/lib/arm64-v8a/libkeydockguard.so"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$SoPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SoPath)) {
    throw "File not found: $SoPath"
}

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $SoPath).Path)

# 1. ELF Header Validation
if ($bytes.Length -lt 64) {
    throw "File too small to be an ELF binary."
}

if ($bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    throw "Invalid ELF magic number."
}

$is64Bit = ($bytes[4] -eq 2)
if (-not $is64Bit) {
    Write-Warning "File is 32-bit ELF. This script is optimized for ARM64 (64-bit)."
}

Write-Host "=== ELF Analysis: $(Split-Path $SoPath -Leaf) ($($bytes.Length) bytes) ===" -ForegroundColor Cyan

# Helper to read UInt64 Little Endian
function Read-U64([byte[]]$b, [int]$off) {
    return [System.BitConverter]::ToUInt64($b, $off)
}

function Read-U32([byte[]]$b, [int]$off) {
    return [System.BitConverter]::ToUInt32($b, $off)
}

function Read-U16([byte[]]$b, [int]$off) {
    return [System.BitConverter]::ToUInt16($b, $off)
}

function Read-String([byte[]]$b, [int]$off) {
    if ($off -lt 0 -or $off -ge $b.Length) { return "" }
    $end = $off
    while ($end -lt $b.Length -and $b[$end] -ne 0) {
        $end++
    }
    if ($end -eq $off) { return "" }
    return [System.Text.Encoding]::UTF8.GetString($b, $off, $end - $off)
}

# 2. Parse Program Headers for VAddr -> FileOffset conversion
$phOff = Read-U64 $bytes 32
$phentsize = Read-U16 $bytes 54
$phnum = Read-U16 $bytes 56

$loadSegments = @()
for ($i = 0; $i -lt $phnum; $i++) {
    $off = $phOff + ($i * $phentsize)
    $p_type = Read-U32 $bytes $off
    if ($p_type -eq 1) { # PT_LOAD
        $p_offset = Read-U64 $bytes ($off + 8)
        $p_vaddr = Read-U64 $bytes ($off + 16)
        $p_filesz = Read-U64 $bytes ($off + 32)
        $p_memsz = Read-U64 $bytes ($off + 40)
        $loadSegments += [pscustomobject]@{
            FileOffset = $p_offset
            VAddr = $p_vaddr
            FileSz = $p_filesz
            MemSz = $p_memsz
        }
    }
}

function VAddr-ToFileOffset([uint64]$vaddr) {
    foreach ($seg in $loadSegments) {
        if ($vaddr -ge $seg.VAddr -and $vaddr -lt ($seg.VAddr + $seg.MemSz)) {
            return [int]($vaddr - $seg.VAddr + $seg.FileOffset)
        }
    }
    return [int]$vaddr # Fallback
}

# 3. Parse Section Headers if present
$e_shoff = Read-U64 $bytes 40
$e_shentsize = Read-U16 $bytes 58
$e_shnum = Read-U16 $bytes 60
$e_shstrndx = Read-U16 $bytes 62

$relaDynOff = 0
$relaDynSize = 0

if ($e_shoff -gt 0 -and $e_shnum -gt 0 -and ($e_shoff + ($e_shnum * $e_shentsize)) -le $bytes.Length) {
    # Read section header string table
    $shstrTabHdrOff = $e_shoff + ($e_shstrndx * $e_shentsize)
    $shstrTabFileOff = [int](Read-U64 $bytes ($shstrTabHdrOff + 24))
    
    for ($i = 0; $i -lt $e_shnum; $i++) {
        $secOff = $e_shoff + ($i * $e_shentsize)
        $sh_name_idx = Read-U32 $bytes $secOff
        $sh_type = Read-U32 $bytes ($secOff + 4)
        $sh_offset = [int](Read-U64 $bytes ($secOff + 24))
        $sh_size = [int](Read-U64 $bytes ($secOff + 32))
        
        $secName = Read-String $bytes ($shstrTabFileOff + $sh_name_idx)
        if ($secName -eq ".rela.dyn") {
            $relaDynOff = $sh_offset
            $relaDynSize = $sh_size
            Write-Host "Found .rela.dyn section at 0x$($relaDynOff.ToString('X')) (size: 0x$($relaDynSize.ToString('X')))" -ForegroundColor Green
            break
        }
    }
}

# Fallback: scan for RELATIVE relocations (type 0x403 = R_AARCH64_RELATIVE)
if ($relaDynOff -eq 0) {
    Write-Host "Scanning program headers / relocation table directly..." -ForegroundColor Yellow
    for ($off = 0x200; $off -lt [Math]::Min(0x4000, $bytes.Length - 24); $off += 8) {
        $r_info = Read-U64 $bytes ($off + 8)
        if ($r_info -eq 0x403) {
            $relaDynOff = $off
            Write-Host "Detected R_AARCH64_RELATIVE relocation block at 0x$($relaDynOff.ToString('X'))" -ForegroundColor Green
            $cur = $off
            while ($cur -lt $bytes.Length - 24 -and ((Read-U64 $bytes ($cur + 8)) -eq 0x403 -or (Read-U64 $bytes ($cur + 8)) -eq 0)) {
                $cur += 24
            }
            $relaDynSize = $cur - $off
            break
        }
    }
}

if ($relaDynOff -eq 0 -or $relaDynSize -lt 24) {
    Write-Warning "Could not automatically locate .rela.dyn table."
    return
}

# 4. Read Relocations
$entryCount = [int]($relaDynSize / 24)
$relas = @()
for ($i = 0; $i -lt $entryCount; $i++) {
    $entryOff = $relaDynOff + ($i * 24)
    $r_offset = Read-U64 $bytes $entryOff
    $r_info = Read-U64 $bytes ($entryOff + 8)
    $r_addend = Read-U64 $bytes ($entryOff + 16)
    $relas += [pscustomobject]@{
        Index = $i
        Offset = $r_offset
        Type = $r_info
        Addend = $r_addend
    }
}

# 5. Search for JNI Signature and Method patterns
Write-Host "`nScanning for potential JNINativeMethod tables..." -ForegroundColor Cyan

$candidates = @()
for ($i = 0; $i -lt $relas.Count - 2; $i++) {
    $nameFileOff = VAddr-ToFileOffset $relas[$i].Addend
    $sigFileOff  = VAddr-ToFileOffset $relas[$i+1].Addend
    $nameCandidate = Read-String $bytes $nameFileOff
    $sigCandidate  = Read-String $bytes $sigFileOff
    $fnVAddr = $relas[$i+2].Addend
    $fnFileOff = VAddr-ToFileOffset $fnVAddr

    # Check if sig matches JNI signature convention
    if ($sigCandidate -match '^\([A-Za-z0-9_/$\[;]*\)[A-Za-z0-9_/$\[;]+$' -and $nameCandidate -match '^[a-zA-Z0-9_<>$]+$') {
        $candidates += [pscustomobject]@{
            MethodName   = $nameCandidate
            Signature    = $sigCandidate
            FnFileOffset = "0x$($fnFileOff.ToString('X'))"
            FnVAddr      = "0x$($fnVAddr.ToString('X'))"
            FnIntOffset  = $fnFileOff
        }
        $i += 2 # Skip the grouped trio
    }
}

if ($candidates.Count -gt 0) {
    Write-Host "Found $($candidates.Count) JNI Native Method(s) mapped dynamically:" -ForegroundColor Green
    $candidates | Format-Table -AutoSize
    
    Write-Host "`nRecommended Binary Patches:" -ForegroundColor Magenta
    foreach ($c in $candidates) {
        if ($c.Signature -match '\)Z$') {
            Write-Host "  $($c.MethodName) ($($c.Signature)) -> File Offset: $($c.FnFileOffset) (Return boolean: MOV W0, #1; RET)" -ForegroundColor Yellow
        } elseif ($c.Signature -match '\)Ljava/lang/String;') {
            Write-Host "  $($c.MethodName) ($($c.Signature)) -> File Offset: $($c.FnFileOffset) (Return string/null: MOV X0, #0; RET)" -ForegroundColor Yellow
        } else {
            Write-Host "  $($c.MethodName) ($($c.Signature)) -> File Offset: $($c.FnFileOffset)"
        }
    }
} else {
    Write-Host "No clear RegisterNatives JNI table pattern matched automatically. Inspect strings manually or check static exports." -ForegroundColor Gray
}
