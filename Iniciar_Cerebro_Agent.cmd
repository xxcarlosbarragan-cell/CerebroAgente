@echo off
setlocal
cd /d "%~dp0"
set "CEREBRO_PORTABLE_LOCAL_TEST="
rem Arranque USB manual. No se instala ni se inicia con Windows.
powershell.exe -NoProfile -Command "$d=New-Object System.IO.DriveInfo('%~d0\'); if($d.DriveType -eq 'Removable'){exit 0}else{exit 1}"
if errorlevel 1 (
  echo Cerebro Agent Portable: para uso normal ejecutalo desde una memoria USB.
  echo Esta carpeta tambien permite una prueba temporal con tu permiso.
  choice /C SN /N /M "Hacer prueba local ahora? [S/N]: "
  if errorlevel 2 exit /b 0
  set "CEREBRO_PORTABLE_LOCAL_TEST=1"
)
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CerebroAgent.ps1"
set "CEREBRO_PORTABLE_LOCAL_TEST="
endlocal
