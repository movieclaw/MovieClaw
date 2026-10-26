param([Parameter(Mandatory)][string]$ServerUrl)
$ErrorActionPreference = 'Stop'
$server = [Uri]$ServerUrl
if (-not $server.IsAbsoluteUri -or $server.Scheme -notin @('http', 'https') -or $server.UserInfo) {
    throw 'Use an absolute HTTP(S) server URL without embedded credentials.'
}
$base = $server.AbsoluteUri.TrimEnd('/')
$bootstrap = Invoke-RestMethod -Uri "$base/api/v1/auth/bootstrap" -TimeoutSec 15
$body = if ($bootstrap.PSObject.Properties['data']) { $bootstrap.data } else { $bootstrap }
$kinds = @($body.native_device_kinds | Where-Object { $_ })
[pscustomobject]@{
    server = $base
    nativeDeviceKinds = $kinds
    windowsPairing = ($kinds -contains 'windows')
    nextStep = if ($kinds -contains 'windows') { 'Use QR login; approve the Windows device on your phone.' }
        else { 'Password login remains available. Upgrade the NAS server before using Windows QR pairing.' }
} | ConvertTo-Json -Depth 3
