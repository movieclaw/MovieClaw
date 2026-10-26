param([ValidateSet('build', 'run', 'all')][string]$Mode = 'all')
$ErrorActionPreference = 'Stop'
if ($Mode -ne 'run') { & (Join-Path $PSScriptRoot 'build.ps1') }
if ($Mode -ne 'build') {
    & (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
    $env:MOVIECLAW_MPV = (Resolve-Path (Join-Path $PSScriptRoot '..\dist\runtime\mpv\mpv.exe')).Path
    $exe = Join-Path $PSScriptRoot '..\src-tauri\target\x86_64-pc-windows-msvc\debug\movieclaw-desktop.exe'
    if (-not (Test-Path $exe)) { throw "Missing executable: $exe" }
    Start-Process -FilePath $exe
}
