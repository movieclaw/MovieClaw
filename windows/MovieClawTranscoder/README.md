# MovieClaw 转码器（Windows）

把 NAS 的硬件转码交给 Windows 电脑上的 NVIDIA 显卡。它是 MovieClaw 远程转码协议的 Windows
Worker 实现，和 [macOS 转码器](../../macos/MovieClawTranscoder/README.md) 说同一套协议
（`docs/design/remote-transcode.md`）：NAS 下发 ffmpeg 任务，Worker 从 NAS 的签名地址读源视频，
用 NVENC 转成 H.264，把 HLS fMP4 分片传回 NAS。NAS 上的 CPU 只做调度，不再扛转码。

纯标准库的 Python 程序，没有第三方依赖。同一份代码有两种用法：

- **应用**（`app/`）：安装包 + 托盘程序，打开就能配对——给普通用户；
- **命令行**（`movieclaw_transcoder/`）：无界面常驻，给服务器、排障和自动化。

两者共用同一份配置、日志与单实例锁，同一台电脑只能跑其中一个。

Worker 不挂载 NAS 文件系统，也不把源视频或转码产物保存到电脑硬盘：ffmpeg 通过 HTTP(S)
读取源文件，输出推到本机回环口，由程序切成分片、边切边传回 NAS，媒体字节只在内存里过一遍。
磁盘上只有普通配置、能力缓存、日志和 CUDA 内核缓存（见下面「文件在哪」）。

## 1. 需要什么

- Windows 10 / 11，支持 NVENC 的 NVIDIA 显卡和较新的显卡驱动（实测 RTX 2070 SUPER）；
- **应用**：什么都不用装——安装包里带 Python 运行时，ffmpeg 首次运行自动下载；
- **命令行**：Python 3.11 或更新，外加 **jellyfin-ffmpeg 的 Windows 版**
  （[发布页](https://github.com/jellyfin/jellyfin-ffmpeg/releases)，下载文件名含 `portable_win64`
  的压缩包解压即可）。

两个用法都要求 jellyfin-ffmpeg：上游 ffmpeg 不行——NAS 的命令用到 `scale_cuda`（带 `format`
选项）和 `tonemapx`，它们是 jellyfin-ffmpeg 的补丁；HDR 片想在显卡上做色调映射还要 `tonemap_cuda`，
jellyfin-ffmpeg 都带。实测版本：8.1.3（应用会自动装这个版本并要求它是 jellyfin 构建）。

## 2. 应用：装完双击就行

### 2.1 安装

装 `MovieClawTranscoder-<版本>-setup-x64.exe`（per-user，装到
`%LOCALAPPDATA%\Programs\MovieClawTranscoder`，不弹 UAC）。不想安装就用
`MovieClawTranscoder-<版本>-portable-x64.zip`，解压后双击目录里的 `MovieClawTranscoder.pyw`。

安装包里带 Python 3.12 运行时（含 tkinter），没有第三方依赖，也不需要另装 Python。

### 2.2 第一次使用

1. 先在 MovieClaw 网页打开「系统 → 应用 → 远程转码」的开关。
2. 双击打开转码器。窗口里的「连接你的 NAS」会自动列出局域网里找到的 movieclaw；只找到一台就
   替用户填好，也可以直接填地址（如 `http://192.168.1.5:3000`）。
3. 点**「连接并配对」**。窗口显示一段大号配对码，同时自动打开浏览器里的批准页——用**管理员账号**
   核对配对码后批准（转码器只能由管理员批准）。批准页没打开的话，到 NAS 网页「设置 → 设备」输入
   这个配对码。
4. 批准后窗口切到状态页：ffmpeg 与显卡自检通过、已连上 NAS、空闲待命。首次运行会先从 Jellyfin
   官方发布页下载 jellyfin-ffmpeg（约 65 MB，SHA256 校验后解压），进度条走完就好。

之后每次开机在托盘里待命（托盘图标右键有：打开 / 立即重连 / 重新配对 / 开机自启 / 打开日志 / 退出）。
左键单击图标打开窗口；关窗口只是收起，不退出。

安装向导的最后一页会把**开机自启**勾上（登录 Windows 后自动运行）；安装后的状态页里也有这个开关，
随时可关。静默安装（`/S`）不会写自启、也不会自动启动。

### 2.3 应用与命令行的差别

| | 应用 | 命令行 |
|---|---|---|
| 入口 | 双击 / 托盘 | `python -m movieclaw_transcoder` |
| 找 NAS | 局域网自动发现 + 填地址 | `--server` |
| ffmpeg | 自动下载官方 jellyfin-ffmpeg | `--ffmpeg` 或 PATH |
| 配对 | 窗口显示配对码、自动开浏览器 | 打印配对码 |
| 状态 | 托盘提示 + 状态页 | 日志 |

应用也接受 `--server` / `--ffmpeg`（跳过发现与下载）和 `--headless`（不开窗口，配对码只写日志），
用于自动化与排障。两者都写 `%APPDATA%\MovieClawTranscoder\`。

## 3. 命令行

先在 MovieClaw 网页打开「系统 → 应用 → 远程转码」的开关（和 Mac 转码器一样，地址和令牌都不用配）。
然后在这个目录里：

```powershell
cd windows\MovieClawTranscoder
python -m movieclaw_transcoder --server http://192.168.1.5:3000 --ffmpeg C:\jellyfin-ffmpeg\ffmpeg.exe
```

`--server` 填 NAS 的局域网地址和端口（转码要来回传输大量视频分片，走公网或反向代理会明显变慢）；
`--ffmpeg` 不填时用 PATH 里的 `ffmpeg`。这两个值和下面的选项都记在配置里，下次直接
`python -m movieclaw_transcoder` 就行。

程序依次做：

1. **自检 ffmpeg 与显卡**：真跑一遍 NAS 会下发的那条 NVENC 链，再逐个编码用几帧样片实测 NVDEC、
   用一段 HDR 样片实测 `tonemap_cuda`。驱动没装、显卡不支持、ffmpeg 不是 jellyfin 构建，都在这里说清楚原因
   和下一步，不会等到第一次播放失败才发现。结果按 ffmpeg 与驱动版本缓存，之后启动很快。
2. **验证 NAS 地址**：连得上、而且确实是 MovieClaw。
3. **配对**：打印一段配对码并打开批准页，用**管理员账号**核对配对码后批准（转码器只能由管理员批准）。
   令牌自动回到这台电脑，全程不需要看到或抄写任何密钥；在「设置 → 设备」里可以单独吊销。
4. **连上 NAS 开始接单**。

看到「已连上 NAS，可以接单」就好了。网页「系统 → 应用 → 远程转码」里能看到这台电脑在线，并可以给它设并发上限。

### 选项

| 选项 | 作用 |
|---|---|
| `--server 地址` | NAS 地址，只需给一次 |
| `--ffmpeg 路径` | ffmpeg.exe 的路径，只需给一次 |
| `--name 名字` | 这台电脑在 NAS 里的名字（字母数字与 `._:-`，默认取主机名） |
| `--max-jobs 1-4` | 想同时转几路；实际以网页「设备」页里给这台设备设的上限为准 |
| `--check` | 只检查 ffmpeg 与显卡、打印将要申报的能力，不连接 NAS |
| `--reset` | 断开配对：在 NAS 上注销这台电脑的凭证、清掉本机令牌，然后重新配对 |

### 开机自启动（命令行）

用应用版本的，在状态页或托盘菜单里勾「开机自启」就行。只想跑命令行的话，给
`pythonw -m movieclaw_transcoder`（不弹控制台窗口）建一个快捷方式，起始位置设成本目录，放进
`shell:startup`。同一台电脑只允许运行一个转码器（命名互斥体），重复启动会直接退出。

## 4. 文件在哪

`%APPDATA%\MovieClawTranscoder\`（环境变量 `MOVIECLAW_TRANSCODER_HOME` 可以改）：

| 文件 | 内容 |
|---|---|
| `config.json` | NAS 地址、令牌、机器名、并发、ffmpeg 路径。令牌只在配对成功的那一刻出现一次 |
| `capabilities.json` | 自检结果缓存（ffmpeg 或驱动换了会自动重测） |
| `transcoder.log` | 日志（滚动，最多约 4 MB）；应用与命令行写同一份 |
| `ffmpeg\versions\` | 应用自动下载的 jellyfin-ffmpeg（按版本分目录，装新的清旧的；手动指了 ffmpeg 就不碰这里） |
| `cuda-cache\` | 给 ffmpeg 用的专属 CUDA 内核缓存，见下 |
| `crash.log` | 只在启动就崩时出现（pythonw 没有控制台，崩因写在这里并弹框提示） |

**为什么有专属的 CUDA 缓存。** `scale_cuda` / `tonemap_cuda` 的内核第一次用要由驱动按这块显卡即时编译（约 2
秒），结果存进 CUDA 的 JIT 缓存。系统默认的缓存（NVIDIA 的 `ComputeCache`，上限 256 MB）被别的程序（PyTorch
之类）塞满之后，新编译的结果存不进去，每次播放起播都白白多等 2 秒（实测同一条命令 2.5 秒 → 0.5 秒）。
你自己设了 `CUDA_CACHE_PATH` 就用你的。

## 4. 它转得了什么、转不了什么

NAS 按这台电脑申报的能力派单。**转不了的任务不会派给它**，由 NAS 本机或别的转码器接：

- 支持：H.264（含 Hi10P）/ HEVC / VP9 / AV1 / MPEG-2 / MPEG-4 / VP8 片源（显卡硬解不了的整段软解，
  编码仍用 NVENC）；SDR、HDR10 / HLG（在显卡上色调映射）、BT.2020 SDR；PGS 字幕烧录；多声道降混；
  输出 H.264、BT.709。实测的样片矩阵和速度见 `docs/design/remote-transcode.md` §7.3。
- 不支持：MPEG-TS 分片（Infuse 等第三方播放器要的）、蓝光原盘（ffconcat 清单）。

## 5. 常见问题

| 看到什么 | 怎么办 |
|---|---|
| 窗口里没有找到 NAS | 不在同一局域网，或 NAS 停了发现、Docker 没映射 UDP 7359：直接填地址（如 `http://192.168.1.5:3000`） |
| 下载 ffmpeg 失败 | 这台电脑连不上 GitHub：挂代理后点「重试」，或点「手动选择 ffmpeg…」指向自己解压的 jellyfin-ffmpeg |
| `这份 ffmpeg 缺少滤镜 scale_cuda…` | 手动选的 ffmpeg 不对：要 jellyfin-ffmpeg（上游 ffmpeg 没有这些滤镜） |
| `NVENC 自检失败…` | 装/更新 NVIDIA 驱动；确认显卡支持 NVENC；别的程序（录屏、直播推流）没把编码会话占满 |
| `服务端尚未启用远程转码` | 回网页「系统 → 应用 → 远程转码」打开开关，程序每分钟重试一次 |
| `这台电脑的授权已失效` | 在网页「设置 → 设备」里被注销了，或 NAS 重装过：点「重新配对…」（命令行加 `--reset`） |
| `MovieClaw 转码器已经在这台电脑上运行了` | 同机只能跑一个；从托盘图标退出旧的（或去任务管理器结束旧的 python 进程） |
| 托盘图标不见了 | Explorer 重启后通常会自动补回；没有就重开一次应用（单实例锁保证不会开两份） |
| 起播比预期慢 | 把 `MOVIECLAW_TRANSCODER_DEBUG=1` 设上再启动：每个任务的 ffmpeg 命令和 stderr 会逐行进日志；网页播放诊断里能看到 Worker 各阶段的耗时 |

## 6. 开发与测试

转码内核在 `movieclaw_transcoder/`，应用外壳在 `app/movieclaw_transcoder_app/`：

| 模块 | 职责 |
|---|---|
| `cli.py` | 命令行入口：自检、配对、启动控制连接 |
| `probe.py` | ffmpeg / 显卡能力探测与缓存（hello 里申报的全是这里实测的结论） |
| `pairing.py` | 设备授权配对（`docs/design/device-auth.md`） |
| `client.py` | 控制连接：重连、握手、心跳、派单 |
| `websocket.py` | RFC 6455 客户端（纯标准库） |
| `job.py` | 一个转码任务：起 ffmpeg、进度、看门狗、暂停与停止 |
| `segmenter.py` / `uploader.py` | 把分片化 MP4 按 HLS 栅格切段，分块回传 NAS（重试、整段兜底） |
| `winproc.py` | 暂停 / 恢复 ffmpeg（`NtSuspendProcess`）、转码器退出时一并结束 ffmpeg（作业对象） |
| `telemetry.py` / `single_instance.py` / `config.py` | 负载采样、单实例锁、本机配置 |
| `app/…/model.py` | 应用编排：配对、ffmpeg 准备、内核启停、托盘要的状态（不 import 界面库） |
| `app/…/window.py` | 主窗口：三步引导（连接 → 批准 → 完成）与状态页（tkinter） |
| `app/…/tray.py` | 系统托盘与右键菜单（ctypes 直调 Shell_NotifyIcon） |
| `app/…/discovery.py` | 局域网找 NAS（UDP 7359，与 Go CLI、macOS 转码器同协议） |
| `app/…/ffmpeg_install.py` | 从 Jellyfin 官方下载 jellyfin-ffmpeg 并校验 SHA256 |
| `app/…/autostart.py` | 开机自启（`HKCU\…\Run`） |
| `scripts/build-app.ps1` / `installer.nsis` | 组装运行目录 → 便携 zip + NSIS 安装包 |

```powershell
# 不需要显卡也不需要 ffmpeg（CI 里跑的就是这两组）
pytest tests/windows_transcoder          # 转码内核
pytest tests/windows_transcoder_app      # 应用外壳（配对/发现/下载/自启，界面用替身）

# 真显卡端到端：隔离的 NAS + 真的 Worker + NVENC，走配对、派单、回传、seek、暂停（需要 jellyfin-ffmpeg）
$env:MOVIECLAW_TEST_FFMPEG = "C:\jellyfin-ffmpeg\ffmpeg.exe"
pytest -m integration tests/playback/test_windows_transcoder_e2e.py

# 应用外壳的真机端到端：用 .pyw 启动脚本走首次运行的完整路径（配对 → 自检 → 接单 → 转码 → 解码）
pytest -m integration tests/playback/test_windows_transcoder_app_e2e.py

# 真浏览器：Chrome + hls.js 点播转出来的流并拖动（另需 Playwright、E2E_CHROMIUM 指到 chrome.exe、pnpm install 过）
pytest -m integration tests/playback/test_windows_transcoder_browser.py

# 样片矩阵（十来分钟，结果就是设计文档 §7.3 的表）；MOVIECLAW_MATRIX_OUT 指定文件时每行结果追加成 JSON
$env:MOVIECLAW_MATRIX = "1"
pytest -m integration tests/playback/test_windows_transcoder_matrix.py
```

### 打安装包

```powershell
cd windows\MovieClawTranscoder
powershell -ExecutionPolicy Bypass -File scripts\build-app.ps1
```

产物在 `dist\`：`MovieClawTranscoder-<版本>-setup-x64.exe`（per-user 安装包）、
`MovieClawTranscoder-<版本>-portable-x64.zip`（解压即用）与 `SHA256SUMS.txt`。

- Python 运行时用 [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
  的 Windows x64 `install_only` 包（钉死版本，第一次构建时下载约 46 MB 到 `%TEMP%` 缓存）；
  不用 PyInstaller，免得杀软误报，出问题也能直接用 `runtime\python\python.exe` 复跑。
- ffmpeg **不打进包**：首次运行从 Jellyfin 官方下载并校验 SHA256（与 macOS 转码器同一架构，
  也顺便拿到最新版本）。
- NSIS 编译用 `makensis`；默认找 electron-builder 的缓存，没有就装
  [NSIS 3](https://nsis.sourceforge.io) 后用 `-Makensis` 指路径（或 `-SkipInstaller` 只出便携包）。
- 脚本是带 BOM 的 UTF-8（Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解析，中文注释全乱；
  `installer.nsis` 同理，`Unicode true` 的脚本必须带 BOM）。
- 装 → 卸已实测干净（`/S` 静默路径）：安装目录、开始菜单文件夹与快捷方式、卸载注册表项都会清掉；
  配置与令牌按设计留在 `%APPDATA%\MovieClawTranscoder`。
- 升级/卸载前会先请正在运行的实例退出（给托盘窗口发 `WM_CLOSE`，最多等 15 秒让它等 ffmpeg 收尾），
  避免覆盖/删除撞上占用的文件。重复打开（开始菜单点第二次）不会弹错误框：第二次启动把已有实例的
  窗口带到前台后自己退出，与 macOS 一致。

