# Builds and runs the Maps server, like the npm scripts of Maps-js:
#   zig build local        ->  run.ps1 -Mode local       (this machine, Maps-js/.env.local, in this window)
#   zig build staging      ->  run.ps1 -Mode staging     (maps.wreseal.com, Maps-js/.env.staging, in this window;
#                                                       -Background starts it hidden instead)
#   zig build production   ->  run.ps1 -Mode production  (the Linux server and pages for Proxmox, in zig-out/production)
# Settings come from Maps-js's .env file for that mode. Roll back staging to Node: stop maps-server.exe,
# then `npm run staging` in C:\MProjects\Maps-js.

param(
    [ValidateSet('local', 'staging', 'production')][string]$Mode = 'staging',
    [string]$Zig = 'C:\Tools\zig-0.17.0\zig.exe',
    # Start staging hidden in the background instead of in this window.
    [switch]$Background
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$js = Join-Path (Split-Path -Parent $repo) 'Maps-js'
$dir = Join-Path $repo "zig-out\$Mode"
$exe = Join-Path $dir 'maps-server.exe'

Push-Location $repo
try {
    $server = if ($Mode -eq 'production') { 'server-linux' } else { 'server' }
    & $Zig build $server -Doptimize=safe; if ($LASTEXITCODE) { throw 'server build failed' }
    & $Zig build web -Doptimize=small; if ($LASTEXITCODE) { throw 'web build failed' }
} finally { Pop-Location }

# The running copy must stop before it can be replaced.
Get-Process maps-server -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
Start-Sleep -Milliseconds 500

# A copy of the server and the pages, so rebuilding does not touch the running one.
New-Item -ItemType Directory -Force $dir | Out-Null
if (Test-Path (Join-Path $dir 'web')) { Remove-Item -Recurse -Force (Join-Path $dir 'web') }
Copy-Item -Recurse (Join-Path $repo 'zig-out\web') (Join-Path $dir 'web')

if ($Mode -eq 'production') {
    Copy-Item (Join-Path $repo 'zig-out\linux\maps-server') $dir -Force
    Write-Output @"
Ready in $dir. On the Proxmox server:
  1. copy maps-server, web/ and C:\MProjects\Maps\regions\*.osm.pbf (into regions/) to one folder;
  2. put Maps-js's .env.production next to them, with MAPS_PUBLIC_DIR=web;
  3. run ./maps-server from that folder (behind Cloudflare Tunnel, plain HTTP).
"@
    return
}
Copy-Item (Join-Path $repo 'zig-out\bin\maps-server.exe') $dir -Force

# Settings: Maps-js's .env file for this mode, plus where this copy keeps its files.
$vars = [ordered]@{}
foreach ($line in Get-Content (Join-Path $js ".env.$Mode")) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $vars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$vars['MAPS_PUBLIC_DIR'] = Join-Path $dir 'web'
$vars['REGIONS_DIR'] = Join-Path $repo 'regions'
$vars['TILE_CACHE_DIR'] = Join-Path $dir 'tiles'

# In this window, like npm run dev / npm run staging: the log shows here and Ctrl+C stops it.
if (-not $Background) {
    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    Write-Output "Maps ($Mode) running in this window (Ctrl+C stops it)"
    Push-Location $dir
    try { & $exe } finally { Pop-Location }
    return
}

# Staging runs on by itself: started by Windows' process service, so it shares no handles with
# this script (a `zig build` would otherwise wait for it), with its settings in .env next to it
# (zig-out is never committed).
$vars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -Encoding ascii (Join-Path $dir '.env')
$cmd = "cmd /c `"`"$exe`" 1>server.log 2>server.err.log`""
# No window (ShowWindow 0): closing a console window would stop the server.
$hidden = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $dir; ProcessStartupInformation = $hidden } | Out-Null
Write-Output "Maps staging started (logs in $dir)"
