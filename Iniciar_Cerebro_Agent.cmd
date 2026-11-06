@echo off
setlocal
cd /d "%~dp0"
rem La politica Bypass aplica solo a este proceso; NO cambia la politica global de Windows.
rem Ejecuta este archivo solo si reconoces y has revisado el contenido del paquete.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CerebroAgent.ps1"
if errorlevel 1 (
  echo.
  echo No se pudo iniciar Cerebro Agent. Consulta el mensaje anterior.
  pause
)
endlocal
