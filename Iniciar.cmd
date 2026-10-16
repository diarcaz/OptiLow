@echo off
rem Lanzador de OptiLow: doble clic. Usa Windows PowerShell 5.1 con ExecutionPolicy Bypass.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1" %*
if errorlevel 1 pause
