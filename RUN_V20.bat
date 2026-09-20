@echo off
setlocal
cd /d "%~dp0"
title Fractured Space v20 Launcher

if not exist "%~dp0FracturedSpaceSoloTrainer_v20.ps1" (
    echo [ERREUR] FracturedSpaceSoloTrainer_v20.ps1 est introuvable.
    pause
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0FracturedSpaceSoloTrainer_v20.ps1"

if errorlevel 1 (
    echo.
    echo Le trainer n'a pas pu etre lance.
    echo Si Windows bloque le script, ne desactive pas Defender/Smart App Control.
    echo Utilise une release signee ou verifie la provenance et les hashes du projet.
    pause
)

endlocal
