param([switch]$RebuildImage)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

if (-not (Test-Path (Join-Path $Root 'settings.env'))) {
    throw 'Copy settings.example.env to settings.env, set both passwords, then run start.bat.'
}

function Get-Setting([string]$Name) {
    $line = Get-Content "$Root\settings.env" | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) { throw "Missing setting: $Name" }
    return ($line -split '=', 2)[1].Trim()
}

$SiteName = Get-Setting 'SITE_NAME'
$AdminPassword = Get-Setting 'ADMIN_PASSWORD'
$DbRootPassword = Get-Setting 'DB_ROOT_PASSWORD'
$HttpPort = Get-Setting 'HTTP_PORT'
$CustomImage = Get-Setting 'CUSTOM_IMAGE'
$CustomTag = Get-Setting 'CUSTOM_TAG'
if ($AdminPassword -like 'CHANGE_ME*' -or $DbRootPassword -like 'CHANGE_ME*' -or
    [string]::IsNullOrWhiteSpace($AdminPassword) -or [string]::IsNullOrWhiteSpace($DbRootPassword)) {
    throw 'Set ADMIN_PASSWORD and DB_ROOT_PASSWORD in settings.env before starting.'
}

Write-Host "== URY on-prem Docker bootstrap ==" -ForegroundColor Cyan

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker was not found. Install/start Docker Desktop, then run start.bat again.'
}
& docker version
if ($LASTEXITCODE -ne 0) { throw 'Docker engine is not available. Start Docker Desktop and retry.' }
& docker compose version
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 is not available.' }

$FrappeDir = Join-Path $Root 'frappe_docker'
$ContainerFile = Join-Path $FrappeDir 'images\layered\Containerfile'
if (-not (Test-Path (Join-Path $FrappeDir 'compose.yaml')) -or -not (Test-Path $ContainerFile)) {
    Write-Host '1/6 Downloading official frappe_docker sources inside a temporary Docker container...'

    if (Test-Path $FrappeDir) {
        Remove-Item $FrappeDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $FrappeDir | Out-Null

    $cloneContainer = 'ury-frappe-clone-' + ([Guid]::NewGuid().ToString('N').Substring(0, 10))
    try {
        & docker create --name $cloneContainer alpine/git:latest clone --depth 1 https://github.com/frappe/frappe_docker.git /repo | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create temporary Git container.' }

        & docker start -a $cloneContainer
        if ($LASTEXITCODE -ne 0) { throw 'Failed to clone frappe_docker repository.' }

        # docker cp avoids Windows bind-mount/path translation problems.
        & docker cp "${cloneContainer}:/repo/." $FrappeDir
        if ($LASTEXITCODE -ne 0) { throw 'Failed to copy frappe_docker files from the temporary container.' }
    } finally {
        & docker rm -f $cloneContainer *> $null
    }
}

if (-not (Test-Path (Join-Path $FrappeDir 'compose.yaml'))) {
    throw "frappe_docker download is incomplete: compose.yaml was not found in $FrappeDir"
}
if (-not (Test-Path $ContainerFile)) {
    throw "frappe_docker download is incomplete: images/layered/Containerfile was not found in $FrappeDir"
}

Write-Host '2/6 Preparing custom applications list...'
Copy-Item "$Root\apps.json" "$FrappeDir\apps.json" -Force

$CustomEnv = @"
FRAPPE_PATH=https://github.com/frappe/frappe
FRAPPE_BRANCH=version-15
ERPNEXT_VERSION=version-15
DB_PASSWORD=$DbRootPassword
CUSTOM_IMAGE=$CustomImage
CUSTOM_TAG=$CustomTag
PULL_POLICY=missing
HTTP_PUBLISH_PORT=$HttpPort
FRAPPE_SITE_NAME_HEADER=$SiteName
"@
[System.IO.File]::WriteAllText("$FrappeDir\ury.env", $CustomEnv, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '3/6 Preparing Frappe + ERPNext + HRMS + URY image...'
Push-Location $FrappeDir
try {
    $Image = "${CustomImage}:${CustomTag}"
    & docker image inspect $Image *> $null
    $ImageExists = ($LASTEXITCODE -eq 0)
    $ImageBuilt = (-not $ImageExists -or $RebuildImage)

    if ($ImageBuilt) {
        $BuildArgs = @(
            'build',
            '--build-arg=FRAPPE_PATH=https://github.com/frappe/frappe',
            '--build-arg=FRAPPE_BRANCH=version-15',
            # apps.json is a BuildKit secret, so its contents and moving branches do not invalidate the cache.
            "--build-arg=CACHE_BUST=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())",
            '--secret=id=apps_json,src=apps.json',
            "--tag=$Image",
            '--file=images/layered/Containerfile'
        )
        $BuildArgs += '.'
        & docker @BuildArgs
        if ($LASTEXITCODE -ne 0) { throw "Custom image build failed ($LASTEXITCODE)." }

        & docker tag $Image "ury-erp-base:${CustomTag}"
        if ($LASTEXITCODE -ne 0) { throw 'Could not preserve the base image for local rebuilds.' }
    } else {
        Write-Host "Using existing image $Image. Pass -RebuildImage to fetch new upstream commits."
    }

    Write-Host '4/6 Generating Docker Compose configuration...'
    $composeText = (& docker compose --env-file ury.env -f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml -f overrides/compose.noproxy.yaml config | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Compose generation failed ($LASTEXITCODE)." }
    [System.IO.File]::WriteAllText((Join-Path $FrappeDir 'compose.ury.yaml'), $composeText, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host '5/6 Starting containers...'
    & docker compose --env-file ury.env -p ury -f compose.ury.yaml up -d
    if ($LASTEXITCODE -ne 0) { throw "Compose up failed ($LASTEXITCODE)." }
    if ($ImageBuilt -and $ImageExists) {
        & docker compose --env-file ury.env -p ury -f compose.ury.yaml up -d --force-recreate --no-deps backend frontend websocket queue-short queue-long scheduler
        if ($LASTEXITCODE -ne 0) { throw 'Could not recreate application containers with the rebuilt image.' }
    }

    Write-Host 'Waiting for backend...'
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bench --version *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'Backend did not become ready. Run logs.bat and inspect the output.' }

    Write-Host '6/6 Creating site and installing ERPNext, HRMS and URY (only on first run)...'
    $siteExistsScript = "test -f sites/$SiteName/site_config.json"
    & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bash -lc $siteExistsScript
    $siteExists = ($LASTEXITCODE -eq 0)

    if (-not $siteExists) {
        & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bench new-site $SiteName --mariadb-root-password $DbRootPassword --admin-password $AdminPassword --mariadb-user-host-login-scope '172.%.%.%'
        if ($LASTEXITCODE -ne 0) { throw 'Site creation failed.' }

        foreach ($app in @('erpnext','hrms','ury')) {
            Write-Host "Installing $app..."
            & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bench --site $SiteName install-app $app
            if ($LASTEXITCODE -ne 0) { throw "Installation of $app failed." }
        }
        & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bench --site $SiteName migrate
        if ($LASTEXITCODE -ne 0) { throw 'Migration failed.' }
    } else {
        Write-Host "Site $SiteName already exists; skipping initial install."
        if ($ImageBuilt) {
            & docker compose --env-file ury.env -p ury -f compose.ury.yaml exec -T backend bench --site $SiteName migrate
            if ($LASTEXITCODE -ne 0) { throw 'Site migration failed.' }
        }
    }

    $oldErrorActionPreference = $ErrorActionPreference

try {
    $ErrorActionPreference = 'Continue'

    & docker compose `
        --env-file ury.env `
        -p ury `
        -f compose.ury.yaml `
        restart frontend backend websocket queue-short queue-long scheduler

    if ($LASTEXITCODE -ne 0) {
        throw "Container restart failed ($LASTEXITCODE)."
    }
}
finally {
    $ErrorActionPreference = $oldErrorActionPreference
}
} finally {
    Pop-Location
}

Write-Host ''
Write-Host 'URY is running.' -ForegroundColor Green
Write-Host "URL:      http://localhost:$HttpPort"
Write-Host 'User:     Administrator'
Write-Host "Password: $AdminPassword"
Write-Host ''
Write-Host 'Change ADMIN_PASSWORD and DB_ROOT_PASSWORD in settings.env BEFORE first production use.' -ForegroundColor Yellow
