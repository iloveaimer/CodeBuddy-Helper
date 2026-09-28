@echo off
title CodeBuddy Helper - Install
rem Keep this file pure ASCII: cmd reads .bat in the OEM code page,
rem so non-ASCII comments break on Windows with a different locale.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 echo.
if errorlevel 1 echo Install did not finish. See messages above.
echo.
pause