# URY local Docker setup

Windows bootstrap for a local Frappe v15, ERPNext v15, HRMS v15, and URY site. The URY app comes from [`DragonDara/bron` branch `v3-stg`](https://github.com/DragonDara/bron/tree/v3-stg). The bootstrap downloads `frappe_docker` during setup; its generated files are kept out of this repository.

## First run

1. Install and start Docker Desktop in Linux containers mode. Docker Compose v2 is included.
2. Clone this repository, or download its ZIP from GitHub.
3. In PowerShell, from this repository's folder, make your local settings file:

   ```powershell
   Copy-Item .\settings.example.env .\settings.env
   notepad .\settings.env
   ```

   Set unique `ADMIN_PASSWORD` and `DB_ROOT_PASSWORD` values. The default site is `ury.localhost` and the default host port is `8888`. Keep `settings.env` private.
4. Run `start.bat`. The first image build downloads and compiles the applications, so it can take several minutes.
5. Open <http://localhost:8888> (or the port in `settings.env`) and sign in as `Administrator` with your `ADMIN_PASSWORD`.

The database and site files live in Docker named volumes and survive container restarts. `stop.bat` stops the stack; `start.bat` starts it again. `status.bat` and `logs.bat` help inspect it. `reset-all-data.bat` removes the stack's containers **and data volumes** after an explicit `DELETE` prompt.

## Update to the latest published `v3-stg`

Run this from the repository folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -RebuildImage
```

This rebuilds the image from the published branches, recreates the app containers, and migrates the site. A normal `start.bat` reuses the existing image.

## Build your local `bron` changes

Clone [`DragonDara/bron`](https://github.com/DragonDara/bron) as a **sibling** folder named `bron` beside this repository. For example, if this repository is `C:\work\ury-local`, place the app at `C:\work\bron`:

```powershell
git clone --branch v3-stg https://github.com/DragonDara/bron.git ..\bron
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rebuild-local.ps1
```

The local rebuild includes the current files in that checkout, builds the frontends and Frappe assets, recreates the app containers, and migrates the site. Run it again after local changes. `start.bat` can be used afterward to start the existing local image without replacing it.

## What stays local

`settings.env` contains passwords. The downloaded `frappe_docker` folder contains generated Compose configuration and site settings. Both paths are ignored by Git. Commit only the template and scripts.
