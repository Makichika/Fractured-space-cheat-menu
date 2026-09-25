@echo off
cd /d "%~dp0"
title Fractured Space v20 Launcher
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0FracturedSpaceSoloTrainer_v20.ps1"
