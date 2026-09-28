@echo off
title CodeBuddy Helper - Uninstall
rem Keep this file pure ASCII: cmd reads .bat in the OEM code page,
rem so non-ASCII comments break on Windows with a different locale.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo.
pause