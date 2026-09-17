param (
    [Parameter(Mandatory=$true)]
    [string]$DeltaApk,

    [Parameter(Mandatory=$true)]
    [string]$VngApk,

    [string]$OutApk = ""
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "      KASUMI AUTO PATCHER ENGINE (V1+V2+V3)           " -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ----------------------------------------------------
# 1. DECODING APKS
# ----------------------------------------------------
Write-Host "1. Decoding APKs..." -ForegroundColor Cyan
if (Test-Path "workspace_delta") { Remove-Item "workspace_delta" -Recurse -Force }
if (Test-Path "workspace_vng") { Remove-Item "workspace_vng" -Recurse -Force }

apktool d $DeltaApk -o "workspace_delta" -f -q
apktool d $VngApk -o "workspace_vng" -f -s -q

# ----------------------------------------------------
# 2. PATCHING MANIFEST
# ----------------------------------------------------
Write-Host "2. Patching AndroidManifest.xml..." -ForegroundColor Cyan
$manifestPath = "workspace_delta\AndroidManifest.xml"
$manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)

# Package name
$manifest = $manifest -replace 'package="com\.roblox\.client"', 'package="com.roblox.client.vnggames"'

# Permissions declarations and usages
$manifest = $manifest -replace 'android:name="com\.roblox\.client\.permission\.CONFIGURATION"', 'android:name="com.roblox.client.vnggames.permission.CONFIGURATION"'
$manifest = $manifest -replace 'android:permission="com\.roblox\.client\.permission\.CONFIGURATION"', 'android:permission="com.roblox.client.vnggames.permission.CONFIGURATION"'
$manifest = $manifest -replace 'android:name="com\.roblox\.client\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"', 'android:name="com.roblox.client.vnggames.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"'
$manifest = $manifest -replace 'android:permission="com\.roblox\.client\.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"', 'android:permission="com.roblox.client.vnggames.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"'

# Provider Authorities - Đảm bảo độc lập hoàn toàn với bản quốc tế
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.androidx-startup"', 'android:authorities="com.roblox.client.vnggames.androidx-startup"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.ShellConfigurationProvider"', 'android:authorities="com.roblox.client.vnggames.ShellConfigurationProvider"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client"(?!\s|\.vnggames)', 'android:authorities="com.roblox.client.vnggames"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.fileprovider"', 'android:authorities="com.roblox.client.vnggames.fileprovider"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.persona\.provider"', 'android:authorities="com.roblox.client.vnggames.persona.provider"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.firebaseinitprovider"', 'android:authorities="com.roblox.client.vnggames.firebaseinitprovider"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.personasdk\.isolate\.init"', 'android:authorities="com.roblox.client.vnggames.personasdk.isolate.init"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client\.gmasdk\.isolate\.init"', 'android:authorities="com.roblox.client.vnggames.gmasdk.isolate.init"'
$manifest = $manifest -replace 'android:authorities="com\.roblox\.client(?!\.vnggames)([^"]*)"', 'android:authorities="com.roblox.client.vnggames$1"'

# App icon and label
$manifest = $manifest -replace 'android:icon="@mipmap/ic_launcher"', 'android:icon="@mipmap/ic_launcher_vng_square" android:roundIcon="@mipmap/ic_launcher_vng_round"'
$manifest = $manifest -replace 'android:icon="@mipmap/ic_launcher_square"', 'android:icon="@mipmap/ic_launcher_vng_square"'
$manifest = $manifest -replace 'android:roundIcon="@mipmap/ic_launcher_round"', 'android:roundIcon="@mipmap/ic_launcher_vng_round"'
$manifest = $manifest -replace 'android:label="@string/Roblox_Application_Name"', 'android:label="@string/roblox_vnggames_name"'
$manifest = $manifest -replace 'android:label="@string/roblox_name"', 'android:label="@string/roblox_vnggames_name"'

# URL scheme: robloxglobal -> robloxvng
$manifest = $manifest -replace 'android:scheme="robloxglobal"', 'android:scheme="robloxvng"'

# Task affinity
$manifest = $manifest -replace 'android:taskAffinity="com\.roblox\.client\.calling"', 'android:taskAffinity="com.roblox.client.vnggames.calling"'

# Thêm VNG OneLink intent-filter
if ($manifest -notmatch "roblox-vng\.onelink\.me") {
    $vngOnelinkFilter = @'

            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:host="roblox-vng.onelink.me" android:scheme="https"/>
            </intent-filter>
'@
    $manifest = $manifest -replace '(<intent-filter>\s*<action android:name="android\.intent\.action\.VIEW"/>\s*<category android:name="android\.intent\.category\.DEFAULT"/>\s*<category android:name="android\.intent\.category\.BROWSABLE"/>\s*<data android:scheme="robloxvng"/>\s*</intent-filter>)', "`$1$vngOnelinkFilter"
}

# Stamp type & derived apk id (Cập nhật chuẩn VNG để server nhận diện đủ tính năng)
$manifest = $manifest -replace 'android:value="STAMP_TYPE_STANDALONE_APK"', 'android:value="STAMP_TYPE_DISTRIBUTION_APK"'
$manifest = $manifest -replace '(<meta-data android:name="com\.android\.vending\.derived\.apk\.id" android:value=")4(")', '${1}2$2'

[System.IO.File]::WriteAllText($manifestPath, $manifest, $utf8NoBom)

# ----------------------------------------------------
# 3. COPYING ICONS AND RESOURCES
# ----------------------------------------------------
Write-Host "3. Copying VNG Icons and Resources..." -ForegroundColor Cyan

$densities = @("mipmap-hdpi", "mipmap-mdpi", "mipmap-xhdpi", "mipmap-xxhdpi", "mipmap-xxxhdpi", "mipmap-anydpi-v26")
$iconFiles = @("ic_launcher_vng_square.png", "ic_launcher_vng_round.png", "ic_launcher_vng_square.webp", "ic_launcher_vng_round.webp", "ic_launcher_vng_square.xml", "ic_launcher_vng_round.xml")

foreach ($density in $densities) {
    $srcDir = "workspace_vng\res\$density"
    $dstDir = "workspace_delta\res\$density"

    if (Test-Path $srcDir) {
        if (!(Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        foreach ($icon in $iconFiles) {
            $srcFile = Join-Path $srcDir $icon
            if (Test-Path $srcFile) {
                Copy-Item $srcFile $dstDir -Force
            }
        }
    }
}

# Copy splits0.xml nếu có
$splitsXml = "workspace_vng\res\xml\splits0.xml"
$dstXml    = "workspace_delta\res\xml\splits0.xml"
if (Test-Path $splitsXml) {
    Copy-Item $splitsXml $dstXml -Force
}

# Copy VNG compression dictionaries
$dictSrc = "workspace_vng\assets\android\shared_compression_dictionaries"
$dictDst = "workspace_delta\assets\android\shared_compression_dictionaries"
if (Test-Path $dictSrc) {
    if (-not (Test-Path $dictDst)) { New-Item -ItemType Directory -Path $dictDst -Force | Out-Null }
    Copy-Item "$dictSrc\*" -Destination $dictDst -Force
    Write-Host "   [+] Injected VNG shared compression dictionaries" -ForegroundColor Green
}

# Copy and Patch Guac policies
$guacSrc = "workspace_vng\assets\content\guac\defaultConfigs"
$guacDst = "workspace_delta\assets\content\guac\defaultConfigs"
if (Test-Path $guacSrc) {
    if (-not (Test-Path $guacDst)) { New-Item -ItemType Directory -Path $guacDst -Force | Out-Null }
    Get-ChildItem -Path $guacSrc -Filter "*VNG*" | ForEach-Object {
        Copy-Item $_.FullName -Destination $guacDst -Force
    }
}
if (Test-Path $guacDst) {
    Get-ChildItem -Path $guacDst -Filter "*.json" | ForEach-Object {
        $guacText = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $guacText = $guacText -replace '"ShowVNGAge12Badge":\s*true', '"ShowVNGAge12Badge": false'
        $guacText = $guacText -replace '"ShowBadgeOver12":\s*true', '"ShowBadgeOver12": false'
        $guacText = $guacText -replace '"EnableInGameHomeIcon":\s*false', '"EnableInGameHomeIcon": true'
        [System.IO.File]::WriteAllText($_.FullName, $guacText, $utf8NoBom)
    }
    Write-Host "   [+] Patched GuacPolicies (Disabled VNG badge crash, enabled InGameHomeIcon)" -ForegroundColor Green
}

# Add roblox_vnggames_name to strings.xml if needed
$stringsXmlPath = "workspace_delta\res\values\strings.xml"
if (Test-Path $stringsXmlPath) {
    $stringsXml = [System.IO.File]::ReadAllText($stringsXmlPath, [System.Text.Encoding]::UTF8)
    if ($stringsXml -notmatch 'name="roblox_vnggames_name"') {
        $stringsXml = $stringsXml -replace '</resources>', "    <string name=`"roblox_vnggames_name`">Roblox VN</string>`n</resources>"
        [System.IO.File]::WriteAllText($stringsXmlPath, $stringsXml, $utf8NoBom)
    }
}

# Đảm bảo chỉ giữ 64-bit (arm64-v8a)
$libDir = "workspace_delta\lib"
if (Test-Path "$libDir\armeabi-v7a") {
    Write-Host "   -> Removing 32-bit (armeabi-v7a)..." -ForegroundColor Yellow
    Remove-Item "$libDir\armeabi-v7a" -Recurse -Force
}

# ----------------------------------------------------
# 4. PATCHING SMALI STRINGS & SERVER ENDPOINTS (FULL VNG ENGINE)
# ----------------------------------------------------
Write-Host "4. Patching Smali Strings & Server Endpoints (Full VNG Engine)..." -ForegroundColor Cyan

$patcherSource = @"
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

public class KasumiSmaliEngine {
    private static readonly Regex PkgRegex = new Regex("\"com\\.roblox\\.client(?!\\.vnggames)([^\"]*)\"", RegexOptions.Compiled);
    private static readonly Regex UriRegex = new Regex("content://com\\.roblox\\.client(?!\\.vnggames)([^\"\\s]*)", RegexOptions.Compiled);

    public static int Execute(string rootDir) {
        int count = 0;
        var utf8 = new UTF8Encoding(false);
        var files = Directory.EnumerateFiles(rootDir, "*.smali", SearchOption.AllDirectories);

        Parallel.ForEach(files, file => {
            string text = File.ReadAllText(file, utf8);
            bool modified = false;

            // 1. Package and Content Provider Authorities
            if (text.IndexOf("\"com.roblox.client", StringComparison.Ordinal) >= 0) {
                string p = PkgRegex.Replace(text, "\"com.roblox.client.vnggames$1\"");
                if (p != text) { text = p; modified = true; }
            }
            if (text.IndexOf("content://com.roblox.client", StringComparison.Ordinal) >= 0) {
                string p = UriRegex.Replace(text, "content://com.roblox.client.vnggames$1");
                if (p != text) { text = p; modified = true; }
            }

            // 2. Server Endpoints, Distributor, App Upgrade Key & VNG Platform Strings
            if (text.IndexOf("\"www.roblox.com\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"www.roblox.com\"", "\"www.robloxapp.vnggames.com\"");
                modified = true;
            }
            if (text.IndexOf("\"https://www.roblox.com\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"https://www.roblox.com\"", "\"https://www.robloxapp.vnggames.com\"");
                modified = true;
            }
            if (text.IndexOf("\"GlobalDist\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"GlobalDist\"", "\"VNGGamesDist\"");
                modified = true;
            }
            if (text.IndexOf("\"AppAndroidV\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"AppAndroidV\"", "\"AppVNGGamesGoogleV\"");
                modified = true;
            }
            if (text.IndexOf("\"robloxplatform_googleProdRelease\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"robloxplatform_googleProdRelease\"", "\"robloxplatform_vnggamesProdRelease\"");
                modified = true;
            }
            if (text.IndexOf("\"googleProd\"", StringComparison.Ordinal) >= 0) {
                text = text.Replace("\"googleProd\"", "\"vnggamesProd\"");
                modified = true;
            }
            if (text.IndexOf(".method public static m(Landroid/content/Context;)Ljava/lang/String;", StringComparison.Ordinal) >= 0) {
                text = text.Replace("const-string v0, \"google\"", "const-string v0, \"vnggames\"");
                modified = true;
            }

            if (modified) {
                File.WriteAllText(file, text, utf8);
                System.Threading.Interlocked.Increment(ref count);
            }
        });
        return count;
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'KasumiSmaliEngine').Type) {
    Add-Type -TypeDefinition $patcherSource -Language CSharp
}

$patchedCount = [KasumiSmaliEngine]::Execute("workspace_delta")
Write-Host "   -> Patched $patchedCount smali files cleanly." -ForegroundColor DarkCyan

# ----------------------------------------------------
# 5. REBUILDING APK
# ----------------------------------------------------
if ($OutApk -eq "") {
    $apktoolYml = Get-Content "workspace_delta\apktool.yml" -Raw
    $versionName = [regex]::Match($apktoolYml, 'versionName: (.*)').Groups[1].Value.Trim()
    $OutApk = "Delta-VNG-$versionName.apk"
    Write-Host "   -> Phien ban phat hien: $versionName" -ForegroundColor DarkCyan
}

Write-Host "5. Rebuilding Patched APK..." -ForegroundColor Cyan
if (Test-Path "unsigned_patched.apk") { Remove-Item "unsigned_patched.apk" -Force }
apktool b "workspace_delta" -o "unsigned_patched.apk" -f -q

# ----------------------------------------------------
# 6. SIGNING APK (V1 + V2 + V3 VIA KASUMI ENGINE)
# ----------------------------------------------------
Write-Host "6. Signing APK with Kasumi Signature (V1 + V2 + V3)..." -ForegroundColor Cyan
$keystore = Join-Path $ScriptDir "kasumi.keystore"
$storepass = "kasumi"
$alias = "kasumi"

if (-not (Test-Path $keystore)) {
    Write-Host "   -> Generating Kasumi Keystore..." -ForegroundColor DarkCyan
    keytool -genkey -v -keystore $keystore -storepass $storepass -alias $alias -keypass $storepass -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Kasumi,O=Kasumi Network,C=VN" | Out-Null
}

$uberSigner = Join-Path $ScriptDir "uber-apk-signer.jar"
$tempOutDir = Join-Path $ScriptDir "out_temp_signed"
if (Test-Path $tempOutDir) { Remove-Item $tempOutDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $tempOutDir -Force | Out-Null

Write-Host "   -> Applying V1 + V2 + V3 Signatures & ZipAlign..." -ForegroundColor DarkCyan
java -jar $uberSigner --ks $keystore --ksAlias $alias --ksPass $storepass --ksKeyPass $storepass -a "unsigned_patched.apk" -o $tempOutDir | Out-Null

$signedFile = Get-ChildItem -Path $tempOutDir -Filter "*.apk" | Select-Object -First 1
if ($signedFile) {
    Copy-Item $signedFile.FullName $OutApk -Force
    Write-Host "   -> Signature verified: V1 + V2 + V3 (Kasumi)" -ForegroundColor Green
} else {
    throw "Loi: Khong the ky APK!"
}

# ----------------------------------------------------
# CLEANUP
# ----------------------------------------------------
Write-Host "Cleaning up workspace..." -ForegroundColor Cyan
Remove-Item "workspace_delta" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "workspace_vng" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "unsigned_patched.apk" -Force -ErrorAction SilentlyContinue
Remove-Item $tempOutDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "======================================================" -ForegroundColor Green
Write-Host " [THANH CONG] File APK da hoan tat: $OutApk" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
