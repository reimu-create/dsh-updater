@echo off
rem ============================================================
rem  Adapt <InstallRoot>\controller.ps1 to the dsh 0.1.5+ token auth.
rem
rem  Run this after the official update.bat has overwritten
rem  controller.ps1, or any time the WebUI opens a blank/401 page.
rem
rem  Idempotent: safe to run again and again.
rem  Options are passed through, e.g.:
rem     Fix-Launcher.bat -DryRun
rem     Fix-Launcher.bat -Path "D:\other\controller.ps1"
rem ============================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-Launcher.ps1" %*
set RC=%ERRORLEVEL%

echo.
if "%RC%"=="0" (
    echo  Done. Exit code 0.
) else (
    echo  Failed. Exit code %RC%  -- controller.ps1 was left unchanged.
)
echo.
pause
