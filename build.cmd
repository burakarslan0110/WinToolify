@echo off
rem Builds dist\WinToolify.ps1 from src\ with nothing but Windows PowerShell.
rem Same script GitHub Actions runs; no modules, no network.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Build-WinToolify.ps1" %*
set WT_BUILD_EXIT=%errorlevel%
echo.
pause
exit /b %WT_BUILD_EXIT%
