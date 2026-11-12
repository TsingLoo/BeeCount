# Runs the project-local Flutter SDK without writing to protected user folders.
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolRoot = Join-Path $repoRoot '.tools'
$env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
$env:TEMP = Join-Path $toolRoot 'temp'
$env:TMP = $env:TEMP
$env:APPDATA = Join-Path $toolRoot 'appdata'
$env:LOCALAPPDATA = Join-Path $toolRoot 'localappdata'
$env:JAVA_HOME = Join-Path $toolRoot 'jdk/jdk-17.0.21+9'
$env:ANDROID_HOME = Join-Path $toolRoot 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $toolRoot 'android-user'
$env:GRADLE_USER_HOME = Join-Path $toolRoot 'gradle'
foreach ($directory in @($env:PUB_CACHE, $env:TEMP, $env:APPDATA, $env:LOCALAPPDATA, $env:ANDROID_USER_HOME, $env:GRADLE_USER_HOME)) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
Set-Location -LiteralPath $repoRoot
& (Join-Path $toolRoot 'flutter/bin/flutter.bat') @args
exit $LASTEXITCODE
