$ErrorActionPreference = 'Stop'

$Project = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TempProject = Join-Path $env:USERPROFILE 'build\pandamj_admin_flutter'
$Dist = Join-Path $Project 'dist'
$Flutter = if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat' } else { 'flutter.bat' }

New-Item -ItemType Directory -Force -Path $TempProject, $Dist | Out-Null
robocopy $Project $TempProject /E /XD .dart_tool build dist .git .gradle | Out-Host
if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }

Push-Location $TempProject
try {
    & $Flutter clean
    & $Flutter pub get
    & $Flutter analyze
    & $Flutter test
    & $Flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw "Flutter Android build failed: $LASTEXITCODE" }
    Copy-Item -Force 'build\app\outputs\flutter-apk\app-release.apk' (Join-Path $Dist '熊猫麻将后台-Flutter-Android.apk')
} finally {
    Pop-Location
}

Write-Host "APK: $(Join-Path $Dist '熊猫麻将后台-Flutter-Android.apk')"
