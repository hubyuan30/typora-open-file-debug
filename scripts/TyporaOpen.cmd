@echo off
rem ============================================================
rem  Typora open wrapper
rem  1) refresh trial state first (no-op if Typora already running)
rem  2) then hand the file over to Typora
rem
rem  usage: TyporaOpen.cmd "D:\path\to\file.md"
rem
rem  NOTE: keep this file ASCII-only. cmd.exe cannot parse UTF-8
rem        comments on GBK code pages and will choke on them.
rem ============================================================
setlocal

set "FIXDIR=%~dp0"
set "TYPORA="
set "PATHFILE=%FIXDIR%..\config\typora-path.txt"

if exist "%PATHFILE%" set /p TYPORA=<"%PATHFILE%"
if not defined TYPORA set "TYPORA=%ProgramFiles%\Typora\Typora.exe"

if not exist "%TYPORA%" (
    echo [TyporaOpen] Typora.exe not found: %TYPORA%
    echo [TyporaOpen] Run Install-TyporaFix.ps1 -TyporaExe "full\path\to\Typora.exe" first.
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%FIXDIR%Keep-TyporaTrial.ps1"

if "%~1"=="" (
    start "" "%TYPORA%"
) else (
    start "" "%TYPORA%" "%~1"
)

endlocal
