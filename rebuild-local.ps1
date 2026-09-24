$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BronDir = Join-Path (Split-Path -Parent $Root) 'bron'
$FrappeDir = Join-Path $Root 'frappe_docker'
$Dockerfile = Join-Path $Root 'Dockerfile.bron'

function Get-Setting([string]$Name) {
    $line = Get-Content (Join-Path $Root 'settings.env') |
        Where-Object { $_ -match "^$([regex]::Escape($Name))=" } |
        Select-Object -First 1
    if (-not $line) { throw "Missing setting: $Name" }
    return ($line -split '=', 2)[1].Trim()
}

$SiteName = Get-Setting 'SITE_NAME'
$CustomImage = Get-Setting 'CUSTOM_IMAGE'
$CustomTag = Get-Setting 'CUSTOM_TAG'
$Image = "${CustomImage}:${CustomTag}"
$BaseImage = "ury-erp-base:${CustomTag}"

if (-not (Test-Path (Join-Path $FrappeDir 'compose.ury.yaml'))) {
    throw 'Run start.bat successfully before rebuilding from bron.'
}
if (-not (Test-Path (Join-Path $BronDir 'pyproject.toml'))) {
    throw "Local bron checkout is missing at $BronDir. Clone https://github.com/DragonDara/bron next to this repository."
}

& docker version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Engine is unavailable. Start Docker Desktop and retry.' }

# Keep the original image so repeated local builds do not stack on prior local builds.
& docker image inspect $BaseImage *> $null
if ($LASTEXITCODE -ne 0) {
    & docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) { throw "Image $Image is missing. Run start.bat first." }
    & docker tag $Image $BaseImage
    if ($LASTEXITCODE -ne 0) { throw "Could not preserve base image as $BaseImage." }
}

Write-Host "Building $Image from $BronDir..." -ForegroundColor Cyan
Push-Location $BronDir
try {
    & docker build --build-arg "BASE_IMAGE=$BaseImage" --file $Dockerfile --tag $Image .
    if ($LASTEXITCODE -ne 0) { throw 'Local image build failed.' }
}
finally {
    Pop-Location
}

Push-Location $FrappeDir
try {
    $ComposeArgs = @('--env-file', 'ury.env', '-p', 'ury', '-f', 'compose.ury.yaml')
    $AppServices = @('backend', 'frontend', 'websocket', 'queue-short', 'queue-long', 'scheduler')

    & docker compose @ComposeArgs up -d --force-recreate --no-deps @AppServices
    if ($LASTEXITCODE -ne 0) { throw 'Could not recreate application containers.' }

    & docker compose @ComposeArgs exec -T backend bench --site $SiteName migrate
    if ($LASTEXITCODE -ne 0) { throw "Migration failed for $SiteName." }
}
finally {
    Pop-Location
}

Write-Host "Local bron image is running at site $SiteName." -ForegroundColor Green
