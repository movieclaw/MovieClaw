param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [string]$InstallerPath,
    [switch]$InstallSmoke
)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path $PackageDirectory).Path
$manifest = Get-Content (Join-Path $PSScriptRoot 'mpv-manifest.json') -Raw | ConvertFrom-Json
$environmentPath = Join-Path $PSScriptRoot '..\dist\smoke-environment.json'
if (-not (Test-Path $environmentPath)) { & (Join-Path $PSScriptRoot 'probe-environment.ps1') -OutputPath $environmentPath }
$environment = Get-Content $environmentPath -Raw | ConvertFrom-Json -AsHashtable
$environment.nativeSmoke = @{}
$null = $environment.Remove('nativeSmokeError')
$runtime = Join-Path $package 'mpv'
foreach ($file in @('movieclaw-desktop.exe', 'LICENSE', 'mpv\runtime-checksums.json', 'mpv\mpv-manifest.json', 'mpv\licenses\VulkanRT-License.txt') + @($manifest.requiredFiles | ForEach-Object { "mpv\$_" }) + @($manifest.licenses | ForEach-Object { "mpv\licenses\$($_.file)" })) {
    if (-not (Test-Path (Join-Path $package $file))) { throw "Package missing: $file" }
}
$inventory = Get-Content (Join-Path $runtime 'runtime-checksums.json') -Raw | ConvertFrom-Json
foreach ($entry in $inventory.PSObject.Properties) {
    $actual = (Get-FileHash (Join-Path $runtime $entry.Name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Runtime checksum mismatch: $($entry.Name)" }
}
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "movieclaw-smoke-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $temp | Out-Null
$player = $null
$app = $null
$pipe = $null
$oldDataDir = $env:MOVIECLAW_DATA_DIR
$oldWebviewDir = $env:WEBVIEW2_USER_DATA_FOLDER
$oldDiagnostics = $env:MOVIECLAW_DIAGNOSTICS
$oldPlatformSmoke = $env:MOVIECLAW_PLATFORM_SMOKE
. (Join-Path $PSScriptRoot 'native-process.ps1')
try {
    & (Join-Path $PSScriptRoot 'mpv-preflight.ps1') -RuntimeDirectory $runtime
    $environment = Get-Content $environmentPath -Raw | ConvertFrom-Json -AsHashtable
    $environment.nativeSmoke = @{}
    $null = $environment.Remove('nativeSmokeError')

    # A finite WAV is seekable and does not require FFmpeg on the runner.
    $wav = Join-Path $temp 'sample.wav'
    $writer = [System.IO.BinaryWriter]::new([System.IO.File]::Create($wav))
    try {
        $samples = 8000 * 5; $dataBytes = $samples * 2
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36 + $dataBytes))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([int16]1); $writer.Write([int16]1); $writer.Write([int]8000); $writer.Write([int]16000)
        $writer.Write([int16]2); $writer.Write([int16]16)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]$dataBytes)
        $writer.Write([byte[]]::new($dataBytes))
    } finally { $writer.Dispose() }
    $pipeName = "movieclaw-smoke-$([guid]::NewGuid().ToString('N'))"
    $player = Start-NativeProcess (Join-Path $runtime 'mpv.exe') @('--no-config', '--vo=null', '--ao=null', '--pause=yes', '--idle=yes', '--keep-open=yes', "--input-ipc-server=\\.\pipe\$pipeName", $wav)
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(5000)
    $inputReader = [System.IO.StreamReader]::new($pipe)
    $outputWriter = [System.IO.StreamWriter]::new($pipe)
    $outputWriter.AutoFlush = $true
    $script:requestNumber = 0
    function Invoke-Mpv([object[]]$Command) {
        $script:requestNumber++
        $id = $script:requestNumber
        $outputWriter.WriteLine((@{ command = $Command; request_id = $id } | ConvertTo-Json -Compress -Depth 5))
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            $read = $inputReader.ReadLineAsync()
            if (-not $read.Wait(3000)) { throw 'mpv IPC response timed out' }
            if (-not $read.Result) { throw 'mpv IPC closed unexpectedly' }
            $reply = $read.Result | ConvertFrom-Json
            if ($reply.request_id -eq $id) {
                if ($reply.error -ne 'success') { throw "mpv IPC failed ($($Command -join ' ')): $($reply.error)" }
                return $reply.data
            }
        }
        throw 'mpv IPC response missing'
    }
    # Duration is available during probing, before the player can accept seek.
    # Require an initialized timeline and seekable demuxer as well.
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $duration = Invoke-Mpv @('get_property', 'duration')
            $position = Invoke-Mpv @('get_property', 'time-pos')
            $seekable = Invoke-Mpv @('get_property', 'seekable')
            if ($duration -ge 4.9 -and $null -ne $position -and $seekable -eq $true) { $ready = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw 'mpv did not load the synthetic WAV' }
    if ((Invoke-Mpv @('get_property', 'pause')) -ne $true) { throw 'mpv pause state incorrect' }
    $seekAccepted = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try { $null = Invoke-Mpv @('seek', 1.0, 'absolute+exact'); $seekAccepted = $true; break }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $seekAccepted) { throw 'mpv did not accept seek after its timeline became available' }
    $null = Invoke-Mpv @('set_property', 'pause', $false)
    if ((Invoke-Mpv @('get_property', 'pause')) -ne $false) { throw 'mpv IPC unpause failed' }
    Start-Sleep -Milliseconds 150
    if ((Invoke-Mpv @('get_property', 'time-pos')) -lt 0.9) { throw 'mpv seek did not move the playback position' }
    $null = Invoke-Mpv @('stop')
    $outputWriter.WriteLine('{"command":["quit"]}')
    if (-not $player.WaitForExit(5000)) { throw 'mpv did not exit after IPC quit' }
    if ($player.ExitCode -ne 0) { throw 'mpv IPC shutdown failed' }
    $pipe.Dispose(); $pipe = $null

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MovieClawSmokeWindow {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int length);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
    function Test-NativeApp([string]$Executable, [string]$Label) {
        $env:MOVIECLAW_DATA_DIR = Join-Path $temp "data-$Label"
        $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $temp "webview2-$Label"
        $env:MOVIECLAW_DIAGNOSTICS = '1'
        $env:MOVIECLAW_PLATFORM_SMOKE = '1'
        $measurement = @{ status = 'starting' }
        $environment.nativeSmoke[$Label] = $measurement
        $startupTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $script:app = Start-Process $Executable -PassThru
        $window = [IntPtr]::Zero
        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            $script:app.Refresh()
            if ($script:app.HasExited) { throw "Tauri app exited during startup: $($script:app.ExitCode)" }
            $window = $script:app.MainWindowHandle
            if ($window -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 100
        }
        if ($window -eq [IntPtr]::Zero) { throw 'Tauri main window was not created' }
        $windowClass = [System.Text.StringBuilder]::new(256)
        $null = [MovieClawSmokeWindow]::GetClassName($window, $windowClass, 256)
        [uint32]$windowProcess = 0
        $null = [MovieClawSmokeWindow]::GetWindowThreadProcessId($window, [ref]$windowProcess)
        $measurement.window = @{ handle = $window.ToInt64(); class = $windowClass.ToString(); title = $script:app.MainWindowTitle; processId = $windowProcess }
        Write-Host "Native window: $($script:app.MainWindowTitle), class=$windowClass, hwnd=$window, owner=$windowProcess"
        if ($windowProcess -ne $script:app.Id) { throw 'Native smoke selected a window from another process' }
        $webviewFound = $false
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            $children = @(Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" | Where-Object { $_.ParentProcessId -eq $script:app.Id })
            if ($children.Count -gt 0) { $webviewFound = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $webviewFound) { throw 'WebView2 browser process did not start' }
        $measurement.windowSeconds = [Math]::Round($startupTimer.Elapsed.TotalSeconds, 3)
        $webviewExecutable = $children[0].ExecutablePath
        if ($webviewExecutable -and (Test-Path $webviewExecutable)) {
            $environment.webview2.runningVersion = (Get-Item $webviewExecutable).VersionInfo.ProductVersion
        }
        $readyPath = Join-Path $env:MOVIECLAW_DATA_DIR 'native-ready.json'
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path $readyPath)) {
            if ($script:app.HasExited) { throw 'Native app exited before the UI bridge became ready' }
            if ([DateTime]::UtcNow -gt $readyDeadline) { throw 'Native UI bridge did not become ready within 15 seconds' }
            Start-Sleep -Milliseconds 100
        }
        $measurement.bridgeReady = Get-Content $readyPath -Raw | ConvertFrom-Json -AsHashtable
        $startupTimer.Stop()
        $measurement.startupSeconds = [Math]::Round($startupTimer.Elapsed.TotalSeconds, 3)
        $measurement.readySeconds = $measurement.startupSeconds
        $platformPath = Join-Path $env:MOVIECLAW_DATA_DIR 'platform-smoke.json'
        $platformDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path $platformPath)) {
            if ($script:app.HasExited -or [DateTime]::UtcNow -gt $platformDeadline) { throw 'Native platform probe did not finish within 15 seconds' }
            Start-Sleep -Milliseconds 100
        }
        $measurement.platform = Get-Content $platformPath -Raw | ConvertFrom-Json -AsHashtable
        if ($measurement.platform.passed -ne $true) { throw 'Native platform lifecycle probe failed' }
        $measurement.status = 'closing'
        $shutdownTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $posted = [MovieClawSmokeWindow]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $measurement.closeMessagePosted = $posted
        if (-not $posted) { throw "WM_CLOSE PostMessage failed: $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        if (-not $script:app.WaitForExit(5000)) { throw 'Tauri shutdown exceeded its bounded cleanup window' }
        $shutdownTimer.Stop()
        $measurement.shutdownSeconds = [Math]::Round($shutdownTimer.Elapsed.TotalSeconds, 3)
        if ($script:app.ExitCode -ne 0) { throw 'Tauri shutdown failed' }
        $measurement.status = 'passed'
        $script:app = $null
    }
    Test-NativeApp (Join-Path $package 'movieclaw-desktop.exe') 'portable'
    if ($InstallSmoke) {
        if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) { throw 'Install smoke requires the built NSIS installer' }
        $installed = Join-Path $temp 'installed'
        $setup = Start-Process $InstallerPath -ArgumentList @('/S', "/D=$installed") -PassThru
        if (-not $setup.WaitForExit(120000)) { $setup.Kill(); throw 'NSIS installation timed out' }
        if ($setup.ExitCode -ne 0) { throw 'NSIS installation failed' }
        foreach ($file in @('movieclaw-desktop.exe', 'mpv\mpv.exe', 'mpv\d3dcompiler_43.dll', 'mpv\vulkan-1.dll', 'mpv\licenses\MPV-GPL.txt', 'mpv\licenses\VulkanRT-License.txt', 'mpv\licenses\Vulkan-Apache-2.0.txt')) {
            if (-not (Test-Path (Join-Path $installed $file))) { throw "Installer missing runtime resource: $file" }
        }
        Test-NativeApp (Join-Path $installed 'movieclaw-desktop.exe') 'installed'
        $uninstaller = Join-Path $installed 'uninstall.exe'
        if (Test-Path $uninstaller) {
            $remove = Start-Process $uninstaller -ArgumentList '/S' -PassThru
            if (-not $remove.WaitForExit(30000)) { $remove.Kill(); throw 'NSIS uninstall timed out' }
            if ($remove.ExitCode -ne 0) { throw 'NSIS uninstall failed' }
        }
    }
    Write-Host 'PASS: package integrity, mpv synthetic decode/IPC, native WebView2 startup and bounded shutdown'
} catch {
    $environment.mpv = (Get-Content $environmentPath -Raw | ConvertFrom-Json -AsHashtable).mpv
    $environment.nativeSmokeError = $_.Exception.Message
    throw
} finally {
    foreach ($label in @('portable', 'installed')) {
        $tracePath = Join-Path $temp "data-$label\shutdown.log"
        if (Test-Path $tracePath) {
            $trace = Get-Content $tracePath -Raw
            $environment.nativeSmoke[$label].shutdownTrace = $trace
            Write-Host "$label shutdown trace: $trace"
        }
    }
    $environment | ConvertTo-Json -Depth 8 | Set-Content $environmentPath -Encoding utf8
    if ($pipe) { $pipe.Dispose() }
    if ($player -and -not $player.HasExited) { $player.Kill() }
    if ($script:app -and -not $script:app.HasExited) { $script:app.Kill() }
    $env:MOVIECLAW_DATA_DIR = $oldDataDir
    $env:WEBVIEW2_USER_DATA_FOLDER = $oldWebviewDir
    $env:MOVIECLAW_DIAGNOSTICS = $oldDiagnostics
    $env:MOVIECLAW_PLATFORM_SMOKE = $oldPlatformSmoke
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
