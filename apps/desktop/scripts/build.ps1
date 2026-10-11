param([ValidateSet('debug', 'release')][string]$Profile = 'debug', [switch]$Tests)
$ErrorActionPreference = 'Stop'
$tauri = Join-Path $PSScriptRoot '..\src-tauri'
$oldRuntime = $env:MOVIECLAW_MPV_RUNTIME
if ($Tests -and -not $oldRuntime) {
    & (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
    $env:MOVIECLAW_MPV_RUNTIME = (Resolve-Path (Join-Path $PSScriptRoot '..\dist\runtime\mpv')).Path
}
Push-Location $tauri
try {
    $buildArgs = @('--locked', '--target', 'x86_64-pc-windows-msvc')
    if ($Profile -eq 'release') { $buildArgs += @('--release', '--features', 'custom-protocol') }
    if ($Tests) { & cargo test @buildArgs -- --nocapture } else { & cargo build @buildArgs }
    if ($LASTEXITCODE -ne 0) { throw 'Rust build/tests failed' }
} finally { Pop-Location; $env:MOVIECLAW_MPV_RUNTIME = $oldRuntime }
