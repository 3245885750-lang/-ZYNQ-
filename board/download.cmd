@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download.ps1" %*
set "radar_exit=%errorlevel%"
pause
exit /b %radar_exit%
