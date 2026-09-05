@echo off
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"%~dp0FracturedSpaceSoloTrainer.ps1\"'"
exit /b
