@echo off
rem Lanzador de OptiLow: doble clic. Usa Windows PowerShell 5.1 con ExecutionPolicy Bypass.
rem Sin argumentos abre la interfaz con la consola OCULTA (si algo falla, un cuadro de aviso lo explica y queda en
rem %TEMP%\OptiLow-error.log). Con argumentos (-Diagnostico, -Listar, -MostrarConsola...) la consola se queda visible.
if "%~1"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1"
) else (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1" %*
    if errorlevel 1 pause
)
