param([switch]$SkipBuild, [switch]$InstallSmoke, [string]$BuildNumber)
$ErrorActionPreference = 'Stop'
if (-not $BuildNumber -and $env:GITHUB_RUN_NUMBER -and $env:GITHUB_RUN_ATTEMPT) { $BuildNumber = "$($env:GITHUB_RUN_NUMBER).$($env:GITHUB_RUN_ATTEMPT)" }
if ($BuildNumber -notmatch '^[1-9][0-9]*\.[1-9][0-9]*$') { throw 'Provide Desktop CI run_number.run_attempt using -BuildNumber' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tauri = Join-Path $root 'src-tauri'
$dist = Join-Path $root 'dist'
$cargo = Get-Content (Join-Path $tauri 'Cargo.toml') -Raw
if ($cargo -notmatch '(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"') { throw 'Missing Cargo package version' }
$version = $Matches[1]
& (Join-Path $PSScriptRoot 'prepare-runtime.ps1')
# The only version source is Cargo.toml. Tauri reads it when config.version is omitted.
# The additional bundle config is generated after the verified runtime exists.
$configPath = Join-Path $dist 'tauri.bundle.conf.json'
$resources = @{}
$resources[(Join-Path $dist 'runtime\mpv').Replace('\', '/') + '/'] = 'mpv/'
@{ bundle = @{ resources = $resources } } | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding utf8
if (-not $SkipBuild) {
    # A cached/local target may contain an installer for an older Cargo version.
    $nsisOutput = Join-Path $tauri 'target\x86_64-pc-windows-msvc\release\bundle\nsis'
    if (Test-Path $nsisOutput) { Remove-Item $nsisOutput -Recurse -Force }
    Push-Location $root
    try {
        & npm exec -- tauri build --target x86_64-pc-windows-msvc --bundles nsis --ci --config $configPath -- --locked
        if ($LASTEXITCODE -ne 0) { throw 'Tauri release/package build failed' }
    } finally { Pop-Location }
}
$target = Join-Path $tauri 'target\x86_64-pc-windows-msvc\release'
$exe = Join-Path $target 'movieclaw-desktop.exe'
$installer = @(Get-ChildItem (Join-Path $target 'bundle\nsis') -Filter '*.exe' -ErrorAction Stop)
if (-not (Test-Path $exe) -or $installer.Count -ne 1) { throw 'Expected one executable and exactly one NSIS installer' }
$portable = Join-Path $dist 'portable'
if (Test-Path $portable) { Remove-Item $portable -Recurse -Force }
New-Item -ItemType Directory -Force $portable | Out-Null
Copy-Item $exe $portable
Copy-Item (Join-Path $dist 'runtime\mpv') $portable -Recurse
Copy-Item (Join-Path $root '..\..\LICENSE') $portable
& python (Join-Path $PSScriptRoot 'audit-dependencies.py') --package $portable --output (Join-Path $dist 'dependency-audit.json')
if ($LASTEXITCODE -ne 0) { throw 'Package requires unbundled runtime DLLs' }
@"
MovieClaw for Windows $version (x64)
Run movieclaw-desktop.exe. UI assets are embedded in the executable.
mpv and its runtime dependencies/licenses are included in mpv/.
The portable package requires Microsoft WebView2 Evergreen Runtime.
The installer includes the offline WebView2 installer and installs it when missing.
"@ | Set-Content (Join-Path $portable 'README.txt') -Encoding utf8
$setupName = "MovieClaw-Windows-$version-Setup-x64.exe"
$zipName = "MovieClaw-Windows-$version-portable-x64.zip"
Copy-Item $installer[0].FullName (Join-Path $dist $setupName) -Force
Compress-Archive -Path "$portable\*" -DestinationPath (Join-Path $dist $zipName) -Force
$hashes = @($setupName, $zipName) | ForEach-Object {
    "$((Get-FileHash (Join-Path $dist $_) -Algorithm SHA256).Hash.ToLowerInvariant())  $_"
}
$hashes | Set-Content (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
& (Join-Path $PSScriptRoot 'smoke.ps1') -PackageDirectory $portable -InstallerPath (Join-Path $dist $setupName) -InstallSmoke:$InstallSmoke
if ($LASTEXITCODE -ne 0) { throw 'Package smoke test failed' }
& (Join-Path $PSScriptRoot 'verify-offline-installer.ps1') -InstallerPath (Join-Path $dist $setupName)
$revision = $env:GITHUB_SHA
if (-not $revision) { $revision = (& git -C $root rev-parse HEAD).Trim() }
$sourceTimestamp = [long](& git -C $root show -s --format=%ct $revision).Trim()
$setupSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $dist $setupName)
$appSignature = Get-AuthenticodeSignature -LiteralPath $exe
$runtimeManifest = Get-Content (Join-Path $PSScriptRoot 'mpv-manifest.json') -Raw | ConvertFrom-Json
$webviewManifest = Get-Content (Join-Path $dist 'offline-webview2.json') -Raw | ConvertFrom-Json
$releaseManifest = @{
    schemaVersion = 1; version = $version; sourceRevision = $revision; sourceTimestamp = $sourceTimestamp
    prerequisites = @{ webview2 = 'bundled-offline-installer'; visualCpp = 'statically-linked'; player = 'bundled-mpv' }
    offlineWebview2 = $webviewManifest
    scope = 'windows-hosted-ci-smoke'; physicalValidated = $false
    files = @(@($setupName, $zipName) | ForEach-Object { $path = Join-Path $dist $_; @{ name = $_; size = (Get-Item $path).Length; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() } })
    runtime = $runtimeManifest
    signatures = @{
        installer = @{ status = $setupSignature.Status.ToString(); thumbprint = $setupSignature.SignerCertificate.Thumbprint }
        application = @{ status = $appSignature.Status.ToString(); thumbprint = $appSignature.SignerCertificate.Thumbprint }
    }
}
$releaseManifest | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $dist 'release-manifest.json') -Encoding utf8
& python (Join-Path $PSScriptRoot 'label-packages.py') --directory $dist --build-number $BuildNumber
if ($LASTEXITCODE -ne 0) { throw 'Build-labeled packages failed' }
Write-Host "Verified packages for MovieClaw for Windows $version are in $dist"
