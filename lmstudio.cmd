@echo off
REM ============================================================================
REM lmstudio.cmd - load/tune an LM Studio model, then run the build against it.
REM Runs via Git Bash. LM Studio must be installed; the script loads the model.
REM Usage:
REM    lmstudio.cmd                              default model (qwen/qwen3.5-9b)
REM    set POCKET_MODEL=google/gemma-4-12b ^&^& lmstudio.cmd   pick another model
REM ============================================================================
setlocal
set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo [lmstudio.cmd] Git Bash not found.
  echo Install Git for Windows ^(https://git-scm.com^), or open a "Git Bash"
  echo terminal in this folder and run:  ./scripts/overnight_lmstudio.sh
  exit /b 1
)
pushd "%~dp0"
"%BASH%" scripts/overnight_lmstudio.sh %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
