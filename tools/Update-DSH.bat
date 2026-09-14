@echo off
rem ============================================================
rem  DeepSeekHarness runtime updater
rem  Double-click this file. It runs OUTSIDE the DSH process tree,
rem  so closing / restarting DSH cannot interrupt the update.
rem
rem  Optional arguments are passed through, e.g.:
rem     Update-DSH.bat -Version 0.1.5-rc.1
rem     Update-DSH.bat -DryRun
rem     Update-DSH.bat -NoRestart
rem ============================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo.
echo  DeepSeekHarness updater - the DSH session will be stopped near the end,
echo  the update itself continues in this window and restarts DSH afterwards.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-dsh.ps1" %*
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo  Finished. Exit code 0.
) else (
    echo  Finished with errors. Exit code %RC%
    echo  See the log in this folder: _update\logs\
)
echo.
pause
