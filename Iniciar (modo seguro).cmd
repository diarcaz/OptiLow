@echo off
rem Lanzador de OptiLow en MODO SEGURO: abre la interfaz con el renderizado por software forzado.
rem Úsalo si la ventana normal sale negra, con basura o no se puede ni tocar la casilla "Renderizado por software"
rem (drivers de video rotos). Consola oculta; los errores salen en un cuadro de aviso.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0OptiLow.ps1" -RenderizadoSoftware
