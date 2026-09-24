@echo off
cd /d "%~dp0frappe_docker"
docker compose --env-file ury.env -p ury -f compose.ury.yaml logs --tail=300 -f
