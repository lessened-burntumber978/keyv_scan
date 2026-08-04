@echo off
REM Keyv Supply-Chain Package Scanner - Windows Batch Wrapper
REM This wrapper runs the PowerShell scanner with proper execution policy

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%check_packages.ps1"
set "CSV_FILE=%~1"

if not exist "%PS_SCRIPT%" (
    echo Error: check_packages.ps1 not found in %SCRIPT_DIR%
    exit /b 2
)

if "%CSV_FILE%:"==":" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" "%CSV_FILE%"
)

exit /b %ERRORLEVEL%