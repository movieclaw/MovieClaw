# MovieClaw 转码器（Windows）构建脚本：组装免安装运行目录 → NSIS 安装包 + 便携 zip。
#
# 产物里没有 PyInstaller：Python 运行时直接用 python-build-standalone 的 install_only
# 整包（自带 tkinter，我们的代码全是标准库），避免杀软误报，出问题也能直接用
# runtime\python\python.exe 手动复跑排查。ffmpeg 不打进包里——首次运行从 Jellyfin
# 官方下载（与 macOS 转码器同一架构），见 app/movieclaw_transcoder_app/ffmpeg_install.py。
#
# 用法（在 windows/MovieClawTranscoder 下）：
#   powershell -File scripts\build-app.ps1 [-Makensis <makensis.exe 路径>]
# 产物落在 dist\：
#   MovieClawTranscoder-<版本>-setup-x64.exe  安装包（per-user，装到 %LOCALAPPDATA%\Programs）
#   MovieClawTranscoder-<版本>-portable-x64.zip  便携版（解压即用）
#   SHA256SUMS.txt

param(
    # NSIS 编译器 makensis.exe。默认找 electron-builder 的缓存（本机打 content-forwarder
    # 安装包时装过）；没有就到 https://nsis.sourceforge.io 装 NSIS 3 后传路径进来。
    [string]$Makensis = "$env:LOCALAPPDATA\electron-builder\Cache\nsis\nsis-3.0.4.1\makensis.exe",

    # Python 运行时（python-build-standalone，Windows x64 install_only），钉死版本保证可复现
    [string]$PythonRelease = "20261021",
    [string]$PythonArchive = "cpython-3.12.15+20261021-x86_64-pc-windows-msvc-install_only.tar.gz",

    # 下载缓存（运行时包只下一次）
    [string]$CacheDir = "$env:TEMP\MovieClawTranscoder-build",

    [switch]$SkipInstaller,  # 只组装便携目录与 zip，不出安装包（没有 NSIS 时的逃生门）

    # 输出目录（默认 dist）。目录被占用时换一个，脚本不硬删
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot          # windows/MovieClawTranscoder
$dist = if ($OutDir) { $OutDir } else { Join-Path $root "dist" }
$payload = Join-Path $dist "payload"
$version = (Select-String -Path (Join-Path $root "app\movieclaw_transcoder_app\__init__.py") `
    -Pattern '__version__ = "(.+?)"').Matches[0].Groups[1].Value
Write-Host "构建 MovieClaw 转码器 $version"

# -- 0. 清场 --------------------------------------------------------------------
if (Test-Path $dist) {
    Remove-Item -Recurse -Force $dist -ErrorAction Stop
    if (Test-Path $dist) { throw "$dist 删不掉（有进程占着？换个 -OutDir）" }
}
New-Item -ItemType Directory -Force -Path $payload, $dist | Out-Null

# -- 1. Python 运行时 ------------------------------------------------------------
$archivePath = Join-Path $CacheDir $PythonArchive
if (-not (Test-Path $archivePath)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $url = "https://github.com/astral-sh/python-build-standalone/releases/download/$PythonRelease/$PythonArchive"
    Write-Host "下载 Python 运行时：$url"
    curl.exe -sL --retry 3 -o $archivePath $url
    if ($LASTEXITCODE -ne 0) { throw "Python 运行时下载失败（如需代理，先设 https_proxy 环境变量再跑）" }
}
New-Item -ItemType Directory -Force -Path (Join-Path $payload "runtime") | Out-Null
Write-Host "解压 Python 运行时…"
# 用系统自带的 bsdtar：PATH 里的 GNU tar（Git Bash）会把 C:\ 当远程主机
& "$env:SystemRoot\System32\tar.exe" -xzf $archivePath -C (Join-Path $payload "runtime")
if ($LASTEXITCODE -ne 0) { throw "运行时包解压失败" }
$pythonExe = Join-Path $payload "runtime\python\python.exe"
if (-not (Test-Path $pythonExe)) { throw "解压后没有 python.exe，运行时包不对" }
& $pythonExe -c "import tkinter, ssl"  # 自带 tkinter 是窗口的前提，缺了立刻报出来

# -- 2. 源码与图标 ----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $payload "app") | Out-Null
Copy-Item -Recurse -Force `
    -Path (Join-Path $root "movieclaw_transcoder"), (Join-Path $root "app\movieclaw_transcoder_app") `
    -Destination (Join-Path $payload "app")
Copy-Item (Join-Path $root "app\MovieClawTranscoder.pyw") $payload
Get-ChildItem $payload -Recurse -Directory -Filter "__pycache__" | Remove-Item -Recurse -Force

# -- 3. 冒烟：组装出来的目录要能跑起自检 ---------------------------------------------
Write-Host "冒烟：导入应用与核心包…"
& $pythonExe -c "import sys; sys.path.insert(0, r'$payload\app'); import movieclaw_transcoder, movieclaw_transcoder_app, movieclaw_transcoder_app.model; from movieclaw_transcoder_app import discovery, ffmpeg_install, autostart; print('smoke OK', movieclaw_transcoder_app.__version__)"
if ($LASTEXITCODE -ne 0) { throw "组装产物导入失败" }

# -- 4. 便携 zip ------------------------------------------------------------------
$portableZip = Join-Path $dist "MovieClawTranscoder-$version-portable-x64.zip"
Write-Host "打便携包：$portableZip"
Compress-Archive -Path $payload\* -DestinationPath $portableZip

# -- 5. NSIS 安装包 ----------------------------------------------------------------
$setupExe = Join-Path $dist "MovieClawTranscoder-$version-setup-x64.exe"
if (-not $SkipInstaller) {
    if (-not (Test-Path $Makensis)) {
        throw "找不到 makensis.exe（$Makensis）。装 NSIS 3 后用 -Makensis 指路径，或加 -SkipInstaller 先出便携包。"
    }
    $iconPath = Join-Path $payload "app\movieclaw_transcoder_app\icon.ico"
    Write-Host "编译安装包：$setupExe"
    # 参数用数组+splat：内联 -DX=(expr) 会让 PowerShell 不展开变量
    $nsisArgs = @(
        "-DVERSION=$version",
        "-DPAYLOAD=$payload",
        "-DOUTFILE=$setupExe",
        "-DICON=$iconPath",
        (Join-Path $PSScriptRoot "installer.nsis")
    )
    & $Makensis @nsisArgs
    if ($LASTEXITCODE -ne 0) { throw "NSIS 编译失败" }
}

# -- 6. 校验和 ---------------------------------------------------------------------
$hashes = @()
Get-ChildItem $dist -File | Where-Object { $_.Extension -in ".exe", ".zip" } | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    $hashes += "$hash  $($_.Name)"
    Write-Host ("  {0}  {1,10:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
$hashes | Set-Content (Join-Path $dist "SHA256SUMS.txt") -Encoding ascii
Write-Host "完成。产物在 $dist"
