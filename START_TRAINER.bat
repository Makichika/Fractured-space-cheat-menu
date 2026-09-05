@echo off
cd /d "%~dp0"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FracturedSpaceSoloTrainer.ps1"
exit /b
