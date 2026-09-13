#Requires -Version 5.1
<#
.SYNOPSIS
    Safely patches ARM64 machine code opcodes directly into an ELF .so binary at a specific file offset.
.PARAMETER SoPath
    Path to the .so file to patch.
.PARAMETER Offset
    File offset (e.g. 0x21D8, "0x21D8", or 8664).
.PARAMETER Pattern
    Pre-configured patch pattern:
    - return-true:  MOV W0, #1; RET  (20 00 80 52 C0 03 5F D6) -> Returns boolean true / int 1
    - return-false: MOV W0, #0; RET  (00 00 80 52 C0 03 5F D6) -> Returns boolean false / int 0
    - return-null:  MOV X0, #0; RET  (00 00 80 D2 C0 03 5F D6) -> Returns pointer null / 0
    - nop:          NOP              (1F 20 03 D5)             -> No operation
.PARAMETER CustomHex
    Custom hex string when Pattern is not used (e.g. "20008052C0035FD6").
.PARAMETER NoBackup
    Skip creating .bak backup file.
.EXAMPLE
    pwsh -File skills/apk-license-bypass/scripts/patch-arm64-so.ps1 -SoPath "app/lib/arm64-v8a/libkeydockguard.so" -Offset 0x21D8 -Pattern "return-true"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$SoPath,

    [Parameter(Mandatory = $true)]
    [object]$Offset,

    [ValidateSet('return-true', 'return-false', 'return-null', 'nop', 'custom')]
    [string]$Pattern = 'return-true',

    [string]$CustomHex = '',

    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SoPath)) {
    throw "Target file not found: $SoPath"
}

$fullPath = (Resolve-Path -LiteralPath $SoPath).Path

# Parse Offset
$targetOffset = 0
if ($Offset -is [int]) {
    $targetOffset = $Offset
} elseif ($Offset -is [string]) {
    if ($Offset -match '^0x[0-9a-fA-F]+$') {
        $targetOffset = [Convert]::ToInt32($Offset, 16)
    } else {
        $targetOffset = [int]::Parse($Offset)
    }
} else {
    $targetOffset = [int]$Offset
}

# Determine replacement bytes
$patchBytes = switch ($Pattern) {
    'return-true'  { [byte[]](0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6) } # MOV W0, #1; RET
    'return-false' { [byte[]](0x00, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6) } # MOV W0, #0; RET
    'return-null'  { [byte[]](0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6) } # MOV X0, #0; RET
    'nop'          { [byte[]](0x1F, 0x20, 0x03, 0xD5) }                         # NOP
    'custom' {
        if (-not $CustomHex) {
            throw "CustomHex is required when Pattern is 'custom'."
        }
        $cleaned = $CustomHex -replace '\s+', ''
        if ($cleaned.Length % 2 -ne 0) {
            throw "CustomHex must contain an even number of hex characters."
        }
        $arr = New-Object byte[] ($cleaned.Length / 2)
        for ($i = 0; $i -lt $cleaned.Length; $i += 2) {
            $arr[$i / 2] = [Convert]::ToByte($cleaned.Substring($i, 2), 16)
        }
        $arr
    }
}

$bytes = [System.IO.File]::ReadAllBytes($fullPath)

if ($targetOffset -lt 0 -or ($targetOffset + $patchBytes.Length) -gt $bytes.Length) {
    throw "Target offset 0x$($targetOffset.ToString('X')) is out of file bounds (file size: $($bytes.Length))."
}

# Backup original file if not already exists
$backupPath = "$fullPath.bak"
if (-not $NoBackup -and -not (Test-Path -LiteralPath $backupPath)) {
    Copy-Item -LiteralPath $fullPath -Destination $backupPath
    Write-Host "Created backup: $backupPath" -ForegroundColor Green
}

# Print Old Bytes
$oldBytes = New-Object byte[] $patchBytes.Length
[Array]::Copy($bytes, $targetOffset, $oldBytes, 0, $patchBytes.Length)
$oldHex = ($oldBytes | ForEach-Object { $_.ToString('X2') }) -join ' '
$newHex = ($patchBytes | ForEach-Object { $_.ToString('X2') }) -join ' '

Write-Host "Patching: $(Split-Path $fullPath -Leaf)" -ForegroundColor Cyan
Write-Host "  File Offset : 0x$($targetOffset.ToString('X')) ($targetOffset)" -ForegroundColor Yellow
Write-Host "  Pattern     : $Pattern" -ForegroundColor Yellow
Write-Host "  Before      : $oldHex" -ForegroundColor Red
Write-Host "  After       : $newHex" -ForegroundColor Green

# Apply patch
for ($i = 0; $i -lt $patchBytes.Length; $i++) {
    $bytes[$targetOffset + $i] = $patchBytes[$i]
}

[System.IO.File]::WriteAllBytes($fullPath, $bytes)
Write-Host "Patch applied successfully!" -ForegroundColor Green
