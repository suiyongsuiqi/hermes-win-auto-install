@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "STATUS_SCRIPT=%SCRIPT_DIR%scripts\windows-check-status.ps1"
set "TARGET_SHELL="
set "PWSH_MAJOR="

where /q pwsh.exe
if not errorlevel 1 (
    for /f "usebackq delims=" %%V in (`pwsh.exe -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul`) do (
        set "PWSH_MAJOR=%%V"
        goto :pwsh_checked
    )
)

:pwsh_checked
if defined PWSH_MAJOR (
    if %PWSH_MAJOR% GEQ 7 (
        set "TARGET_SHELL=pwsh.exe"
    )
)

if not defined TARGET_SHELL (
    where /q powershell.exe
    if not errorlevel 1 (
        set "TARGET_SHELL=powershell.exe"
    )
)

if not defined TARGET_SHELL (
    echo Failed to find PowerShell 7.x or Windows PowerShell.
    echo Install PowerShell and try again.
    pause
    exit /b 1
)

start "" "%TARGET_SHELL%" -NoLogo -NoExit -NoProfile -ExecutionPolicy Bypass -File "%STATUS_SCRIPT%" %*
exit /b 0
