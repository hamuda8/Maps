# Runs the Zig Maps server as staging (maps.wreseal.com through the Cloudflare tunnel, port 5005).
# Settings come from Maps-js/.env.staging (the same database and Valhalla key the Node staging
# server used). Run from anywhere:  powershell -File C:\MProjects\Maps\tools\staging.ps1
# Roll back to Node: stop maps-server.exe, then `npm run staging` in C:\MProjects\Maps-js.

$ErrorActionPreference = 'Stop'
$maps = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path (Split-Path -Parent $maps) 'Maps-js\.env.staging'
$dir = Join-Path $maps 'zig-out\staging'

# A copy of the server and the web pages, so rebuilding Maps does not touch the running one.
New-Item -ItemType Directory -Force $dir | Out-Null
Copy-Item (Join-Path $maps 'zig-out\bin\maps-server.exe') $dir -Force
if (Test-Path (Join-Path $dir 'web')) { Remove-Item -Recurse -Force (Join-Path $dir 'web') }
Copy-Item -Recurse (Join-Path $maps 'zig-out\web') (Join-Path $dir 'web')

foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim().Trim('"'), 'Process')
    }
}
$env:PORT = '5005'
$env:MAPS_PUBLIC_DIR = Join-Path $dir 'web'
$env:REGIONS_DIR = Join-Path $maps 'regions'
$env:TILE_CACHE_DIR = Join-Path $dir 'tiles'

Start-Process -FilePath (Join-Path $dir 'maps-server.exe') -WorkingDirectory $dir -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $dir 'server.log') -RedirectStandardError (Join-Path $dir 'server.err.log')
Write-Output "Zig Maps staging started on port 5005 (logs in $dir)"
