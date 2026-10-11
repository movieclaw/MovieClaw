param([Parameter(Mandatory)][string]$PackageDirectory, [int]$IdleSeconds = 60, [int]$Cycles = 20)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-process.ps1')
$package = (Resolve-Path $PackageDirectory).Path
$mpv = Join-Path $package 'mpv\mpv.exe'
$output = Join-Path $PSScriptRoot '..\dist\native-performance.json'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "movieclaw-performance-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $temporary | Out-Null
$sourceRevision = $env:GITHUB_SHA
if (-not $sourceRevision) { $sourceRevision = ((& git -C (Join-Path $PSScriptRoot '../../..') rev-parse HEAD) | Out-String).Trim() }
$runtimeManifest = Get-Content (Join-Path $package 'mpv\mpv-manifest.json') -Raw | ConvertFrom-Json
$report = @{ schemaVersion = 1; sourceRevision = $sourceRevision; mpvExecutableSha256 = (Get-FileHash $mpv -Algorithm SHA256).Hash.ToLowerInvariant(); mpvManifestVersion = $runtimeManifest.version; recordedAtUtc = [DateTime]::UtcNow.ToString('o'); scope = 'Windows hosted VM process/CPU-decoder baseline'; hardwareOutputMeasured = $false; macHardwareComparable = $false; displayFirstFrameMeasured = $false; completed = $false; idle = @{}; codecs = @(); cycles = @() }
$oldData = $env:MOVIECLAW_DATA_DIR; $oldWebview = $env:WEBVIEW2_USER_DATA_FOLDER; $oldDiagnostics = $env:MOVIECLAW_DIAGNOSTICS; $oldPlatform = $env:MOVIECLAW_PLATFORM_SMOKE
$app = $null; $player = $null; $pipe = $null
function Get-TreeSample([int]$RootProcess) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $ids = [Collections.Generic.HashSet[int]]::new(); $null = $ids.Add($RootProcess)
    do { $added = $false; foreach ($process in $all) { if ($ids.Contains([int]$process.ParentProcessId) -and $ids.Add([int]$process.ProcessId)) { $added = $true } } } while ($added)
    $cpu = @{}; [long]$memory = 0
    foreach ($id in $ids) { $process = Get-Process -Id $id -ErrorAction SilentlyContinue; if ($process) { $cpu[$id] = $process.TotalProcessorTime.TotalSeconds; $memory += $process.WorkingSet64 } }
    return @{ cpuByPid = $cpu; workingSetBytes = $memory; processCount = $cpu.Count }
}
function Measure-Codec([string]$Fixture) {
    $process = Start-NativeProcess $mpv @('--no-config','--terminal=yes','--hwdec=no','--vo=null','--ao=null','--untimed',$Fixture) -Capture
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync(); $clock = [Diagnostics.Stopwatch]::StartNew(); [long]$peak = 0
    try {
        while (-not $process.HasExited) {
            try { $process.Refresh(); $peak = [Math]::Max($peak, $process.WorkingSet64) } catch { if (-not $process.HasExited) { throw } }
            if ($clock.Elapsed.TotalSeconds -gt 60) { $process.Kill(); throw 'CPU codec decode timed out' }; Start-Sleep -Milliseconds 25
        }
        $process.WaitForExit(); $clock.Stop()
        if ($process.ExitCode -ne 0) { throw "CPU codec decode failed: $($stderr.Result)" }
        return @{ elapsedMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 2); cpuSeconds = [Math]::Round($process.TotalProcessorTime.TotalSeconds, 3); peakWorkingSetBytes = $peak; exitCode = $process.ExitCode; decoder = 'software; vo=null; ao=null'; log = ($stdout.Result + $stderr.Result).Trim() }
    } finally { $process.Dispose() }
}
function Invoke-PerformanceMpv([object[]]$Command) {
    $script:requestNumber++; $id = $script:requestNumber
    $script:writer.WriteLine((@{command=$Command; request_id=$id}|ConvertTo-Json -Compress -Depth 6))
    for ($attempt=0; $attempt -lt 100; $attempt++) {
        $line = $script:reader.ReadLineAsync(); if (-not $line.Wait(3000) -or -not $line.Result) { throw 'Performance IPC response timed out' }
        $reply=$line.Result|ConvertFrom-Json
        if ($reply.request_id -eq $id) { if ($reply.error -ne 'success') {throw "Performance IPC failed: $($reply.error)"}; return $reply.data }
    }
    throw 'Performance IPC response missing'
}
function Get-CodecParameters([string]$Fixture) {
    $name = "movieclaw-codec-$([guid]::NewGuid().ToString('N'))"
    $probe = Start-NativeProcess $mpv @('--no-config','--terminal=no','--hwdec=no','--vo=null','--ao=null','--pause=yes','--idle=yes',"--input-ipc-server=\\.\pipe\$name",$Fixture)
    $connection = [IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
    try {
        $connection.Connect(5000)
        $script:reader = [IO.StreamReader]::new($connection); $script:writer = [IO.StreamWriter]::new($connection); $script:writer.AutoFlush = $true; $script:requestNumber = 0
        $parameters = $null
        for ($attempt=0; $attempt -lt 40; $attempt++) {
            try { $parameters = Invoke-PerformanceMpv @('get_property','video-dec-params'); if ($parameters.w -gt 0) { break } } catch {}
            Start-Sleep -Milliseconds 50
        }
        if (-not $parameters -or $parameters.w -le 0) { throw 'Decoded codec parameters never became available' }
        $script:writer.WriteLine('{"command":["quit"]}')
        if (-not $probe.WaitForExit(5000) -or $probe.ExitCode -ne 0) { throw 'Codec metadata probe did not exit cleanly' }
        return $parameters
    } finally { $connection.Dispose(); if (-not $probe.HasExited) { $probe.Kill(); $probe.WaitForExit() }; $probe.Dispose() }
}
try {
    # Encoding is fixture preparation, never included in decoder timing. No extra FFmpeg executable is used.
    $inventory = Invoke-MpvProcess $mpv @('--no-config','--terminal=yes','--ovc=help')
    if ($inventory.exitCode -ne 0) { throw 'Pinned mpv encoder inventory failed' }
    $encoderLog = ($inventory.stdout + $inventory.stderr).Trim()
    $available = @('libx264','libx265','libvpx-vp9','libaom-av1','libsvtav1','librav1e') | Where-Object { [regex]::IsMatch($encoderLog, '(?<![a-zA-Z0-9_])' + [regex]::Escape($_) + '(?![a-zA-Z0-9_-])') }
    $report.encoderInventory = @{ available = @($available); log = $encoderLog }
    $av1 = @('libaom-av1','libsvtav1','librav1e') | Where-Object { $_ -in $available } | Select-Object -First 1
    $av1Options = switch ($av1) { 'libaom-av1' { 'cpu-used=8,crf=40,b=0,threads=2' } 'libsvtav1' { 'preset=12,crf=40,threads=2' } 'librav1e' { 'speed=10,threads=2' } default { '' } }
    $matrix = @(
        @{name='h264'; size='1920x1080'; encoder='libx264'; frames=48; options='preset=ultrafast,crf=28,threads=2'; required=$true},
        @{name='hevc'; size='3840x2160'; encoder='libx265'; frames=48; options='preset=ultrafast,crf=28,threads=2'; required=$true},
        @{name='hevc-main10'; size='320x180'; encoder='libx265'; frames=6; options='preset=ultrafast,crf=28,threads=2,profile=main10'; required=$false; pixelFormat='yuv420p10'},
        @{name='vp9'; size='320x180'; encoder='libvpx-vp9'; frames=6; options='deadline=realtime,cpu-used=8,crf=40,b=0,threads=2'; required=$false},
        @{name='av1'; size='320x180'; encoder=$av1; frames=6; options=$av1Options; required=$false}
    )
    foreach ($codec in $matrix) {
        $row = @{ codec=$codec.name; resolution=$codec.size; frames=$codec.frames; encoder=$codec.encoder; scope='short synthetic software-decoder compatibility only'; status='unsupported' }
        if (-not $codec.encoder -or $codec.encoder -notin $available) {
            $row.reason='No matching encoder in the pinned mpv build'; $report.codecs += $row
            if ($codec.required) { throw "Pinned runtime lacks required $($codec.name) encoder" }; continue
        }
        $fixture = Join-Path $temporary "$($codec.name).mkv"
        $arguments = @('--no-config','--terminal=yes','--no-audio',"--frames=$($codec.frames)","--ovc=$($codec.encoder)","--ovcopts=$($codec.options)","--o=$fixture", "av://lavfi:testsrc2=size=$($codec.size):rate=24:duration=2")
        if ($codec.pixelFormat) { $arguments += "--vf=format=fmt=$($codec.pixelFormat)" }
        $encode = Start-NativeProcess $mpv $arguments -Capture
        try {
            $stdout=$encode.StandardOutput.ReadToEndAsync(); $stderr=$encode.StandardError.ReadToEndAsync()
            if (-not $encode.WaitForExit(90000)) { $encode.Kill(); $encode.WaitForExit(); throw 'Synthetic codec fixture encoding timed out' }
            $encode.WaitForExit(); $row.encoderLog = ($stdout.Result + $stderr.Result).Trim()
            $encoded = $encode.ExitCode -eq 0 -and (Test-Path $fixture) -and (Get-Item $fixture).Length -gt 0
            if (-not $encoded) {
                $row.reason="Encoder could not generate this fixture (exit $($encode.ExitCode))"; $report.codecs += $row
                if ($codec.required) { throw "Synthetic $($codec.name) encoding failed: $($row.encoderLog)" }; continue
            }
        } finally { $encode.Dispose() }
        $row.decodedParameters = Get-CodecParameters $fixture
        if ($codec.name -eq 'hevc-main10' -and $row.decodedParameters.pixelformat -notin @('yuv420p10','yuv420p10le','420p10')) {
            $row.reason="Requested Main10, but actual decoded pixel format is $($row.decodedParameters.pixelformat)"; $report.codecs += $row; continue
        }
        if ($codec.name -eq 'hevc-main10') { $row.bitDepth=10; $row.profile='Main10; constrained encoder plus actual 4:2:0 10-bit decoded pixels' }
        $row.fixtureSha256 = (Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.codecs += $row
        try { $row.measurement = Measure-Codec $fixture; $row.status='passed' } catch { $row.status='failed'; $row.reason=$_.Exception.Message; throw }
    }

    # These are actual bundled-mpv process cycles. The report does not claim WebView/embedded-render cycles.
    $existing = @(Get-Process mpv -ErrorAction SilentlyContinue | ForEach-Object {$_.Id})
    for ($cycle=0; $cycle -lt $Cycles; $cycle++) {
        $pipeName="movieclaw-performance-$([guid]::NewGuid().ToString('N'))"; $readyClock=[Diagnostics.Stopwatch]::StartNew()
        $player=Start-NativeProcess $mpv @('--no-config','--terminal=no','--vo=null','--ao=null','--hwdec=no','--pause=yes','--idle=yes','--keep-open=yes',"--input-ipc-server=\\.\pipe\$pipeName",(Join-Path $temporary 'h264.mkv'))
        $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$pipeName,[IO.Pipes.PipeDirection]::InOut); $pipe.Connect(5000)
        $script:reader=[IO.StreamReader]::new($pipe);$script:writer=[IO.StreamWriter]::new($pipe);$script:writer.AutoFlush=$true;$script:requestNumber=0
        $loaded=$false
        for ($attempt=0;$attempt -lt 40;$attempt++) { try { $params=Invoke-PerformanceMpv @('get_property','video-dec-params'); if ($params.w -eq 1920 -and $params.h -eq 1080) {$loaded=$true;break} } catch {} Start-Sleep -Milliseconds 50 }
        if (-not $loaded) {throw 'Native CPU decoder did not become ready'}
        $readyClock.Stop(); $seekClock=[Diagnostics.Stopwatch]::StartNew(); $null=Invoke-PerformanceMpv @('seek',0.5,'absolute+exact')
        $seeked=$false
        for ($attempt=0;$attempt -lt 30;$attempt++) { $position=Invoke-PerformanceMpv @('get_property','time-pos'); if ($position -ge 0.4 -and $position -le 0.8) {$seeked=$true;break}; Start-Sleep -Milliseconds 20 }
        if (-not $seeked) {throw 'Native exact seek did not settle'}; $seekClock.Stop(); $player.Refresh()
        $row=@{index=$cycle;decoderReadyMs=[Math]::Round($readyClock.Elapsed.TotalMilliseconds,2);exactSeekMs=[Math]::Round($seekClock.Elapsed.TotalMilliseconds,2);workingSetBytes=$player.WorkingSet64;cpuSeconds=[Math]::Round($player.TotalProcessorTime.TotalSeconds,3);scope='standalone bundled mpv; null video/audio outputs';displayFirstFrameMs=$null}
        $null=Invoke-PerformanceMpv @('set_property','pause',$false); $null=Invoke-PerformanceMpv @('set_property','pause',$true)
        $script:writer.WriteLine('{"command":["quit"]}'); if (-not $player.WaitForExit(5000) -or $player.ExitCode -ne 0) {throw 'Native playback cycle did not exit cleanly'}
        $row.exitCode=$player.ExitCode; $report.cycles += $row; $pipe.Dispose();$pipe=$null;$player.Dispose();$player=$null
    }
    $remaining=@(Get-Process mpv -ErrorAction SilentlyContinue | Where-Object {$_.Id -notin $existing})
    if ($remaining.Count -gt 0) {throw 'Native playback cycles left an mpv process'}
    $report.cycleCount=$Cycles; $report.remainingMpvProcesses=$remaining.Count

    $env:MOVIECLAW_DATA_DIR=Join-Path $temporary 'app-data';$env:WEBVIEW2_USER_DATA_FOLDER=Join-Path $temporary 'webview2';$env:MOVIECLAW_DIAGNOSTICS='1';$env:MOVIECLAW_PLATFORM_SMOKE='0'
    $app=Start-Process (Join-Path $package 'movieclaw-desktop.exe') -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(20);$ready=Join-Path $env:MOVIECLAW_DATA_DIR 'native-ready.json'
    while (-not (Test-Path $ready)) {if ($app.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw 'Tauri performance baseline never became ready'}; Start-Sleep -Milliseconds 100}
    $clock=[Diagnostics.Stopwatch]::StartNew();$previous=Get-TreeSample $app.Id;$previousTime=0;$samples=@()
    while ($clock.Elapsed.TotalSeconds -lt $IdleSeconds) {
        Start-Sleep -Milliseconds 1000; if ($app.HasExited) {throw 'Tauri exited during idle sampling'}
        $sample=Get-TreeSample $app.Id;$time=$clock.Elapsed.TotalSeconds; [double]$cpuDelta=0
        foreach ($id in $sample.cpuByPid.Keys) {if ($previous.cpuByPid.ContainsKey($id)) {$cpuDelta += [Math]::Max(0,$sample.cpuByPid[$id]-$previous.cpuByPid[$id])}}
        $samples += @{seconds=[Math]::Round($time,3);cpuCorePercent=[Math]::Round(100*$cpuDelta/($time-$previousTime),3);workingSetBytes=$sample.workingSetBytes;processCount=$sample.processCount}
        $previous=$sample;$previousTime=$time
    }
    $report.idle=@{scope='Tauri plus descendant WebView2 processes after native bridge ready';elapsedSeconds=[Math]::Round($clock.Elapsed.TotalSeconds,3);samples=$samples;cpuPercentConvention='100% means one logical core';maxWorkingSetBytes=($samples|Measure-Object workingSetBytes -Maximum).Maximum;meanCpuCorePercent=($samples|Measure-Object cpuCorePercent -Average).Average}
    $app.CloseMainWindow() | Out-Null; if (-not $app.WaitForExit(5000) -or $app.ExitCode -ne 0) {throw 'Tauri performance baseline did not close cleanly'}
    $report.completed=$true
} catch { $report.error=$_.Exception.Message; throw } finally {
    if ($pipe) {$pipe.Dispose()}; if ($player -and -not $player.HasExited) {$player.Kill()}; if ($app -and -not $app.HasExited) {$app.Kill()}
    $env:MOVIECLAW_DATA_DIR=$oldData;$env:WEBVIEW2_USER_DATA_FOLDER=$oldWebview;$env:MOVIECLAW_DIAGNOSTICS=$oldDiagnostics;$env:MOVIECLAW_PLATFORM_SMOKE=$oldPlatform
    $report | ConvertTo-Json -Depth 12 | Set-Content $output -Encoding utf8
    Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
