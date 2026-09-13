#Requires -Version 5.1
<#
.SYNOPSIS
    Rebuilds an APK from an apktool decoded directory, automatically generates a debug keystore if needed,
    and signs the APK with jarsigner.
.PARAMETER ApktoolDir
    Path to the directory containing decoded apktool files (with apktool.yml).
.PARAMETER OutputApk
    Path to save the generated signed APK.
.PARAMETER KeystorePath
    Optional custom keystore path. If omitted, uses/creates a debug.keystore in the parent of ApktoolDir.
.EXAMPLE
    pwsh -File skills/apk-license-bypass/scripts/rebuild-and-sign.ps1 -ApktoolDir "DN_PROXY_1.0/apktool" -OutputApk "DN_PROXY_bypassed.apk"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ApktoolDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputApk,

    [string]$KeystorePath = '',
    [string]$KeystorePass = 'android',
    [string]$KeyAlias = 'androiddebugkey',
    [string]$KeyPass = 'android'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ApktoolDir)) {
    throw "Apktool directory not found: $ApktoolDir"
}

$apktoolYml = Join-Path $ApktoolDir "apktool.yml"
if (-not (Test-Path -LiteralPath $apktoolYml)) {
    throw "Invalid apktool directory (apktool.yml missing): $ApktoolDir"
}

# 1. Rebuild with apktool
Write-Host "=== Rebuilding APK with apktool... ===" -ForegroundColor Cyan
$tempUnsigned = [System.IO.Path]::GetTempFileName() + ".apk"

try {
    & apktool b "$ApktoolDir" -o "$tempUnsigned" --no-crunch
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempUnsigned)) {
        throw "Apktool build failed with exit code $LASTEXITCODE"
    }
    Write-Host "Apktool build succeeded!" -ForegroundColor Green

    # 2. Keystore Management
    if (-not $KeystorePath) {
        $parentDir = Split-Path (Resolve-Path $ApktoolDir).Path -Parent
        $KeystorePath = Join-Path $parentDir "debug.keystore"
    }

    if (-not (Test-Path -LiteralPath $KeystorePath)) {
        Write-Host "Generating debug keystore at: $KeystorePath" -ForegroundColor Yellow
        & keytool -genkey -v -keystore "$KeystorePath" -storepass $KeystorePass -alias $KeyAlias -keypass $KeyPass -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to generate keystore."
        }
    }

    # 3. Signing
    Write-Host "Signing APK with jarsigner..." -ForegroundColor Cyan
    & jarsigner -sigalg SHA256withRSA -digestalg SHA-256 -keystore "$KeystorePath" -storepass $KeystorePass -keypass $KeyPass "$tempUnsigned" $KeyAlias
    if ($LASTEXITCODE -ne 0) {
        throw "jarsigner failed with exit code $LASTEXITCODE"
    }

    # Move to final output
    $finalOut = (Resolve-Path -Path (Split-Path $OutputApk -Parent) -ErrorAction SilentlyContinue)
    if ($finalOut) {
        $outFinalPath = Join-Path $finalOut.Path (Split-Path $OutputApk -Leaf)
    } else {
        $outFinalPath = $OutputApk
    }

    Move-Item -LiteralPath $tempUnsigned -Destination $outFinalPath -Force
    Write-Host "Successfully generated signed APK: $outFinalPath" -ForegroundColor Green

    # Display SHA256
    $hash = (Get-FileHash -LiteralPath $outFinalPath -Algorithm SHA256).Hash
    Write-Host "  File Size : $((Get-Item $outFinalPath).Length) bytes" -ForegroundColor Gray
    Write-Host "  SHA256    : $hash" -ForegroundColor Yellow

} finally {
    if (Test-Path -LiteralPath $tempUnsigned) {
        Remove-Item -LiteralPath $tempUnsigned -Force -ErrorAction SilentlyContinue
    }
}
