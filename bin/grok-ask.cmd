@echo off
setlocal DisableDelayedExpansion
where.exe pwsh.exe >nul 2>nul
if errorlevel 1 goto ps51
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0grok-ask.ps1" %*
exit /b %ERRORLEVEL%
:ps51
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0grok-ask.ps1" %*
exit /b %ERRORLEVEL%
