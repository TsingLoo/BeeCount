# Uses the Dart SDK bundled with the project-local Flutter installation.
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $repoRoot '.tools'
$env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
$env:TEMP = Join-Path $toolRoot 'temp'
$env:TMP = $env:TEMP
$env:APPDATA = Join-Path $toolRoot 'appdata'
$env:LOCALAPPDATA = Join-Path $toolRoot 'localappdata'
foreach ($directory in @($env:PUB_CACHE, $env:TEMP, $env:APPDATA, $env:LOCALAPPDATA)) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
Set-Location -LiteralPath $repoRoot
& (Join-Path $toolRoot 'flutter/bin/cache/dart-sdk/bin/dart.exe') @args
exit $LASTEXITCODE
