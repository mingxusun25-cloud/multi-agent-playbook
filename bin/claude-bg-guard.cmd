@echo off
setlocal DisableDelayedExpansion
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
python -I "%~dp0claude-bg-guard.py"
exit /b %ERRORLEVEL%
