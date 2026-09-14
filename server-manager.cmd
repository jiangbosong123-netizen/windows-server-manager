@echo off
setlocal
cd /d "%~dp0"
title Windows Server Manager

rem Update the manager before it starts. Offline use still works.
if exist ".git" git pull --ff-only origin main

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-manager.ps1"
if errorlevel 1 (
  echo.
  echo The manager stopped because of an error.
  pause
)
