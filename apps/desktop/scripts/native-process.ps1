function Start-NativeProcess([string]$Executable, [string[]]$Arguments, [switch]$Capture) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = Split-Path $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $Capture.IsPresent
    $start.RedirectStandardError = $Capture.IsPresent
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    return [System.Diagnostics.Process]::Start($start)
}

function Invoke-MpvProcess([string]$Executable, [string[]]$Arguments) {
    # Use the playback .exe with explicit redirected handles; the .com wrapper
    # depends on the caller's console inheritance.
    $process = Start-NativeProcess $Executable $Arguments -Capture
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Bundled mpv process timed out' }
        $process.WaitForExit()
        return @{ exitCode = $process.ExitCode; stdout = $stdout.Result; stderr = $stderr.Result }
    } finally { $process.Dispose() }
}
