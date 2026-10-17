@echo off
rem Lanzador de OptiLow: doble clic. Usa Windows PowerShell 5.1 con ExecutionPolicy Bypass.
rem Sin argumentos abre la interfaz: PowerShell va OCULTO y esta ventana muestra "Abriendo OptiLow..." hasta que la
rem ventana de OptiLow (o un aviso de error) aparece. Si algo falla, un cuadro de aviso lo explica y queda en
rem %TEMP%\OptiLow-error.log. Con argumentos (-Diagnostico, -Listar, -MostrarConsola...) la consola se queda visible.
if not "%~1"=="" goto consola
set "SENAL=%TEMP%\OptiLow-abierto.flag"
del "%SENAL%" >nul 2>nul
echo.
echo   Abriendo OptiLow, puede tardar unos segundos...
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1"
rem Espera (hasta 2 minutos) a que OptiLow cree la senal de que ya hay ventana o aviso
for /l %%i in (1,1,120) do if not exist "%SENAL%" ping -n 2 127.0.0.1 >nul
exit /b 0

:consola
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1" %*
if errorlevel 1 pause
