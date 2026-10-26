param([Parameter(Mandatory)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$sevenZip = (Get-Command 7z -ErrorAction Stop).Source
$inspection = Join-Path ([IO.Path]::GetTempPath()) "movieclaw-offline-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $inspection | Out-Null
try {
    & $sevenZip x $installer "-o$inspection" '*WebView2*' -r -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the packaged WebView2 payload' }
    $payload = @(Get-ChildItem -LiteralPath $inspection -Recurse -File -Filter '*WebView2*.exe')
    if ($payload.Count -ne 1 -or $payload[0].Length -lt 50MB) { throw 'Full offline WebView2 installer is missing (bootstrapper alone is insufficient)' }
    $signature = Get-AuthenticodeSignature -LiteralPath $payload[0].FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw 'The embedded WebView2 installer must have a valid Microsoft signature'
    }
    $report = @{ name = $payload[0].Name; size = $payload[0].Length; sha256 = (Get-FileHash -LiteralPath $payload[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant(); signature = $signature.Status.ToString(); publisher = $signature.SignerCertificate.Subject }
    $report | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot '..\dist\offline-webview2.json') -Encoding utf8
} finally {
    # This exact GUID directory was created above and contains only extracted inspection files.
    $resolvedInspection = (Resolve-Path -LiteralPath $inspection).Path
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedInspection.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedInspection) -notmatch '^movieclaw-offline-[a-f0-9]{32}$') { throw 'Inspection cleanup path escaped the temporary directory' }
    Remove-Item -LiteralPath $resolvedInspection -Recurse -Force
}
