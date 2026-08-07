@echo off
setlocal
set PYTHON=D:\codex_envs\wall-defect-inspector-venv\Scripts\python.exe
if exist "%PYTHON%" (
  "%PYTHON%" "%~dp0app.py"
) else (
  python "%~dp0app.py"
)
if errorlevel 1 pause
