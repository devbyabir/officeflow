@echo off
rem Starts OfficeFlow. Double-click this file and keep its window open while you use OfficeFlow.
rem Your data is kept in %LOCALAPPDATA%\OfficeFlow, not in this folder.
setlocal
title OfficeFlow
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\launch.ps1"
if errorlevel 1 (
  echo.
  echo OfficeFlow could not start or stopped because of the problem shown above.
  echo For help, open "Quick Start.txt" in this folder.
)
echo.
pause
