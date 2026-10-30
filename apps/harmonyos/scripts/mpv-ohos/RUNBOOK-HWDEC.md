# 硬解修复重编 runbook（HISI 10-bit 花屏 round 1）

## 根因（真机 2026-10-30 定位）

嫁金钗 = 3840x2160@60 10-bit HEVC。HISI 硬解 buffer 模式忽略 Configure 阶段的
NV12 请求：实际输出 P010 内存（HCODEC 统计 out≈11.5Gbps@60fps ≈ 24MB/帧 = 4K P010），
但仍上报 NV12。ffmpeg ohdec.c 的 oh_decode_wrap_sw_buffer 按 NV12 拷贝 →
UV 偏移读错 + Y 平面只读一半 → 花屏。

## 修复内容（本目录已备好）

- `patches/apply-ffmpeg-patch.py`（新文件）：ohdec.c 按 capacity/stride 检测
  10-bit P010 布局 → P010→NV12 降位拷贝（自动探测 10-bit 在高/低字节），
  一次性 WARN 布局日志；on_stream_changed 打印协商布局；8-bit 路径不变。
- `build-all.sh`：build_ffmpeg 增加上述补丁步骤；新增 PATCHES_VER 机制
  （版本变化自动删 ffmpeg/mpv stamp 强制重建）。
- app 侧（Windows 已改好并构建）：mpv_napi.cpp 现在把 warn 级 mpv 日志
  转发到 hilog（原来只转 error/fatal，warn 全丢）。

## Mac 步骤

1. 同步本目录（scripts/mpv-ohos/）到 Mac，重点新文件/改动：
   `patches/apply-ffmpeg-patch.py`、`build-all.sh`。
2. `zsh build-all.sh`
   —— 首次运行会提示"补丁版本变化…强制重建 ffmpeg + mpv"，
   ffmpeg 约 10-15 分钟 + mpv 约 5-10 分钟。
3. 成功后把 `$MPV_OHOS_APP_LIBS_DIR/libmpv.so`（即 entry/libs/arm64-v8a/libmpv.so）
   拷回 Windows 覆盖：`D:\MovieClaw\apps\harmonyos\entry\libs\arm64-v8a\libmpv.so`
   顺带 `scripts/mpv-ohos/BUILT-VERSIONS.txt`。
4. 若编译失败：把 `$MPV_OHOS_LOGS/ffmpeg.log`（或 mpv.log）末尾 100 行发回。

## 交回后（Windows 侧，我来执行）

1. MpvPlayer.ets `'hwdec': 'no'` → `'ohcodec-copy'`，rebuild + install 真机。
2. 播放嫁金钗 E02 验证：画面不花、StatsSheet 显示「硬解 ohcodec-copy」。
3. hilog 过滤 `ohdec:`，期望看到一次性日志：
   `10-bit buffer as NV12: 3840x2160 stride=… cap=… lane=N (emax=… omax=…) -> P010->NV12 downconvert`
   - lane=1 且画面正常 → 修复成立，收尾。
   - 出现 `8-bit buffer …` 却仍花屏 → 检测未命中，把日志发回分析。
   - lane=0 或画面偏暗/异常 → 字节通道探测方向错，把日志发回，round 2 翻转。
4. 对比掉帧 / app CPU / 温度（对比软解基线）。

## 预期风险（round 2 候补）

- 降位拷贝每帧 ~25MB 读 + 12MB 写（4K60），若 CPU 占用偏高可改 P010 直通
  （保 10-bit，走 GLES 16-bit 纹理路径）或加 NEON。
- 画面质量：输出从 10-bit 降到 8-bit（屏幕本身 8-bit，HDR 高光会有截断）。
