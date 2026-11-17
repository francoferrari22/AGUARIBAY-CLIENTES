@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "REMOTE=https://francoferrari22@github.com/francoferrari22/AGUARIBAY-CLIENTES.git"
echo ==========================================
echo   AGUARIBAY - Subiendo a GitHub
echo ==========================================
if not exist ".git" git init
git checkout -B main
git config user.name "francoferrari22"
git config user.email "francoferrari22@users.noreply.github.com"
git add -A
git commit -m "Actualizacion AGUARIBAY"
git remote remove origin >nul 2>&1
git remote add origin %REMOTE%
git push -u origin main --force
if errorlevel 1 (
  echo.
  echo FALLO la subida. Copia el mensaje de error de arriba y envialo.
  pause
  exit /b 1
)
echo.
echo Listo. Espera 1-2 minutos a que GitHub Actions publique y recarga la web con Ctrl+F5.
pause
