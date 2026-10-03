@echo off
setlocal
title Rewindle Installer
set "RESTICBACKUPER_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%RESTICBACKUPER_POWERSHELL%" (
  echo Required 64-bit Windows PowerShell was not found.
  pause
  exit /b 1
)
"%RESTICBACKUPER_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ResticBackuper.ps1" %*
set "RESTICBACKUPER_EXIT=%ERRORLEVEL%"
echo.
if not "%RESTICBACKUPER_EXIT%"=="0" echo Installation did not complete. Review the message above.
pause
exit /b %RESTICBACKUPER_EXIT%
