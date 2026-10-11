param([string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\dist\runtime\mpv'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-process.ps1')
$runtime = (Resolve-Path $RuntimeDirectory).Path
$environmentPath = Join-Path $PSScriptRoot '..\dist\smoke-environment.json'
if (-not (Test-Path $environmentPath)) { & (Join-Path $PSScriptRoot 'probe-environment.ps1') -OutputPath $environmentPath }
$environment = Get-Content $environmentPath -Raw | ConvertFrom-Json -AsHashtable
$executable = Join-Path $runtime 'mpv.exe'
try {
    $version = Invoke-MpvProcess $executable @('--no-config', '--terminal=yes', '--version')
    $versionOutput = $version.stdout + $version.stderr
    Write-Host "mpv --version exit code: $($version.exitCode)"
    Write-Host $versionOutput.Trim()
    $environment.mpv.versionExitCode = $version.exitCode
    $environment.mpv.actualVersion = $versionOutput.Trim()
    if ($version.exitCode -ne 0 -or $versionOutput -notmatch '\bmpv\b') {
        throw "Bundled mpv --version failed (exit $($version.exitCode)): $versionOutput"
    }
    # Real deterministic CPU/null video decoding; CI does not test HDR displays.
    $decoder = Invoke-MpvProcess $executable @('--no-config', '--terminal=yes', '--vo=null', '--ao=null', '--frames=5', 'av://lavfi:testsrc=size=64x64:rate=24')
    Write-Host ($decoder.stdout + $decoder.stderr).Trim()
    $environment.mpv.decodeExitCode = $decoder.exitCode
    if ($decoder.exitCode -ne 0) { throw "mpv synthetic video decode failed (exit $($decoder.exitCode))" }
    $null = $environment.mpv.Remove('preflightError')
    Write-Host 'PASS: bundled mpv version and synthetic decoding'
} catch {
    $environment.mpv.preflightError = $_.Exception.Message
    throw
} finally {
    $environment | ConvertTo-Json -Depth 8 | Set-Content $environmentPath -Encoding utf8
}
