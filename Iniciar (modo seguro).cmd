@echo off
rem Lanzador de OptiLow en MODO SEGURO: abre la interfaz con el renderizado por software forzado.
rem Usalo si la ventana normal sale negra, con basura o no se puede ni tocar la casilla "Renderizado por software"
rem (drivers de video rotos). PowerShell va oculto; esta ventana muestra "Abriendo OptiLow..." hasta que aparece.
set "SENAL=%TEMP%\OptiLow-abierto.flag"
del "%SENAL%" >nul 2>nul
echo.
echo   Abriendo OptiLow (modo seguro), puede tardar unos segundos...
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1" -RenderizadoSoftware
for /l %%i in (1,1,120) do if not exist "%SENAL%" ping -n 2 127.0.0.1 >nul
exit /b 0
