@echo off
rem ============================================================
rem  DeepSeek Harness one-click installer launcher
rem  Double-click this file to start the GUI installer.
rem ============================================================
setlocal
title DeepSeek Harness Installer

set "PS1=%~dp0DSHInstaller.ps1"
if not exist "%PS1%" (
  echo.
  echo [ERROR] DSHInstaller.ps1 was not found next to this launcher.
  echo         Expected location: %PS1%
  echo.
  pause
  exit /b 1
)

rem ---- Administrator rights are required: Chocolatey installs software machine-wide ----
if /i "%~1"=="elevated" goto :run

fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges, please confirm the UAC dialog ...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList 'elevated'"
  exit /b 0
)

:run
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=pwsh.exe"

start "" "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
