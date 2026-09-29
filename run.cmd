@echo off
REM ---------------------------------------------------------------------
REM  Minecraft 26.3 / Fabric mod installer
REM
REM  This file is intentionally plain, readable batch. Nothing is encoded,
REM  packed, or obfuscated, and it does not touch antivirus, Defender
REM  exclusions, AMSI, or any other security control.
REM
REM  It does one thing: hand off to install-mods.ps1, which is where the
REM  real work happens. Pass any arguments straight through, e.g.
REM      run.cmd -IncludeOptional
REM      run.cmd -GameVersion 26.3
REM ---------------------------------------------------------------------
setlocal
title Minecraft Fabric Mod Installer

where powershell >nul 2>&1
if errorlevel 1 (
    echo [XX] Windows PowerShell was not found on PATH. Cannot continue.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-mods.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [ok] Done.
) else (
    echo [XX] Finished with exit code %RC%.
)
echo.
pause
exit /b %RC%
