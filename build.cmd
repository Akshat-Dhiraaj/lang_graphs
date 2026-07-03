@echo off
REM ============================================================================
REM build.cmd - run the Pocket Agent builder via Git Bash (NOT WSL/PowerShell).
REM Usage:
REM    build.cmd            full build (auto-detects LM Studio if running)
REM    build.cmd --check    generate + compile-check only (fast, no install)
REM    build.cmd --clean    wipe the build dir first, then build
REM ============================================================================
setlocal
set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo [build.cmd] Git Bash not found.
  echo Install Git for Windows ^(https://git-scm.com^), or open a "Git Bash"
  echo terminal in this folder and run:  ./scripts/build_pocket_agent.sh
  exit /b 1
)
pushd "%~dp0"
"%BASH%" scripts/build_pocket_agent.sh %*
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
