@echo off
chcp 65001 >nul
title Kasumi Auto Patcher - Delta to VNG
color 0B

echo.
echo  ======================================================
echo  ^|^|                                                  ^|^|
echo  ^|^|              KASUMI AUTO PATCHER                 ^|^|
echo  ^|^|             [Delta - Roblox VNG]                 ^|^|
echo  ^|^|                                                  ^|^|
echo  ======================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "DELTA_APK="
set "VNG_APK="

:: Tim file Delta
for %%f in (*Delta*.apk) do (
    echo %%f | findstr /i /v "Delta-VNG-" >nul
    if not errorlevel 1 (
        set "DELTA_APK=%%f"
        goto :found_delta
    )
)
:found_delta

:: Tim file VNG
for %%f in (*vnggames*.apk *roblox*.apk) do (
    echo %%f | findstr /i /v "Delta-VNG-" >nul
    if not errorlevel 1 (
        if not "%%f"=="%DELTA_APK%" (
            set "VNG_APK=%%f"
            goto :found_vng
        )
    )
)
:found_vng

if "%DELTA_APK%"=="" (
    echo [LOI] Khong tim thay file APK cua Delta!
    echo Vui long chep file APK Delta vao cung thu muc nay.
    echo.
    pause
    exit /b
)

if "%VNG_APK%"=="" (
    echo [LOI] Khong tim thay file APK cua Roblox VNG!
    echo Vui long chep file APK VNG goc vao cung thu muc nay.
    echo.
    pause
    exit /b
)

echo [KASUMI] Da phat hien file Delta: %DELTA_APK%
echo [KASUMI] Da phat hien file VNG: %VNG_APK%
echo.
echo Dang tien hanh Patch tu dong... (Vui long khong dong cua so nay)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%patch-delta-vng.ps1" -DeltaApk "%DELTA_APK%" -VngApk "%VNG_APK%"

echo.
pause
