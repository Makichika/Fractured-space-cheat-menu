@echo off
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0FracturedSpaceSoloTrainer.ps1" -DebugConsole
echo.
echo Trainer closed. This window also shows live bot difficulty preset verification.
pause
