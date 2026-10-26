param([string]$OutputPath = (Join-Path $PSScriptRoot '..\dist\smoke-environment.json'))
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
$cpus = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
$gpus = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion, CurrentHorizontalResolution, CurrentVerticalResolution)
$webviews = @()
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients', 'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients')) {
    if (Test-Path $root) {
        foreach ($client in Get-ChildItem $root) {
            $properties = Get-ItemProperty $client.PSPath
            if ($properties.name -like '*WebView*') {
                $webviews += @{ name = $properties.name; version = $properties.pv }
            }
        }
    }
}
$manifest = Get-Content (Join-Path $PSScriptRoot 'mpv-manifest.json') -Raw | ConvertFrom-Json
$environment = [ordered]@{
    schemaVersion = 1
    recordedAtUtc = [DateTime]::UtcNow.ToString('o')
    purpose = 'Windows CI smoke baseline only; not a real-machine playback or performance benchmark.'
    os = @{ name = $os.Caption; version = $os.Version; build = $os.BuildNumber }
    cpus = $cpus
    gpus = $gpus
    tools = @{
        rustc = ((& rustc --version) | Out-String).Trim()
        cargo = ((& cargo --version) | Out-String).Trim()
        node = ((& node --version) | Out-String).Trim()
        python = ((& python --version) | Out-String).Trim()
    }
    mpv = @{ manifestVersion = $manifest.version; archiveSha256 = $manifest.sha256; vulkanLoaderVersion = $manifest.vulkanLoader.version; vulkanLoaderSha256 = $manifest.vulkanLoader.binarySha256 }
    webview2 = @{ registryVersions = $webviews }
    nativeSmoke = @{}
}
New-Item -ItemType Directory -Force (Split-Path $OutputPath) | Out-Null
$environment | ConvertTo-Json -Depth 8 | Set-Content $OutputPath -Encoding utf8
Write-Host "Recorded CI smoke environment: $OutputPath"
