@echo off
rem Double-click to build dist\SinSpire-ModLoader-Patch.exe. --no-pause is for running this from a script.
title Build Sin Spire Mod Loader Patch
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0build.ps1" -Pick
set result=%errorlevel%
echo.
if %result% neq 0 (
    echo The build failed. The reason is above.
) else (
    echo Done. The patch is in the dist folder.
    if not "%~1"=="--no-pause" explorer "%~dp0dist"
)
if not "%~1"=="--no-pause" pause
exit /b %result%
