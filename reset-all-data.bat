@echo off
set /p CONFIRM=This deletes ALL URY containers, database and site data. Type DELETE to continue:
if /I not "%CONFIRM%"=="DELETE" exit /b 0
cd /d "%~dp0frappe_docker"
docker compose --env-file ury.env -p ury -f compose.ury.yaml down -v --remove-orphans
pause
