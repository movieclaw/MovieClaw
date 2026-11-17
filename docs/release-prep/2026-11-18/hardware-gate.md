# 硬件验收：可用条件、实测与解阻路径

状态：**未关闭硬件 P1，不可触发服务器发布**。本文件不将 Apple 或软件测试换算成 Linux GPU 验收。

## 已确认可用的机器与权限

- 本技术会话只确认 `yee-homebook`：Apple M2 Max、30 核 Apple GPU、Darwin arm64；本机 FFmpeg / ffprobe 为 Homebrew 8.1.2。
- 仓库 `hwprobe.probe_backends(force=True)` 真编码自检：VideoToolbox available=true；VAAPI / QSV / NVENC 均因缺对应编码器 available=false。
- 本机存在 Linux/aarch64 Docker daemon，但它不是 Intel / NVIDIA / AMD GPU 的证明。没有进入、停止或修改用户已有容器。
- 仅做只读库存查询：两个已配置 Hermesh connector 的 `project_list` 均返回 UNAUTHORIZED / requires reauthentication；本机 `hermesh project list` 返回 not_paired。本会话没有登录 / 配对、申请新凭据、读取 SSH key / NAS 凭据，也没有扩展远程访问。
- 当前会话的联系人目录只列代理账号，不提供远程 GPU 机器信息。**这不等于用户没有 NAS，只表示本技术会话没有已可用的远程库存入口。** 不因工具无法列出就宣称“无硬件”。

## 本机已实际执行的合成验证

仅使用公开 `lavfi testsrc2` / `sine`，全部文件、日志与输出在独立临时目录，无私有媒体、用户账号或部署。使用候选代码的 `build_hls_command` 生成真实命令，再运行 ffmpeg / ffprobe；硬件编码显式加 `-allow_sw 0`，禁止 VideoToolbox 编码软件兜底。

| 实际场景 | 结果 | 覆盖范围 |
|---|---|---|
| 1080p HEVC + DTS → HEVC + AAC | pass，输出 7.968 秒 | 音频单转、视频原样、实际解封装 / 编码 |
| VideoToolbox 硬解 → CPU 缩放 → VideoToolbox H.264 硬编 720p | pass，输出 8 秒、ffmpeg 报 drop_frames=0 | 保守能力申报下的真实桥接路径，不是全 GPU 缩放 |
| 同一路径从 4 秒重启 seek | pass，剩余输出 4 秒、drop_frames=0 | 实际命令重启、分片、输出尺寸 / 编码 |
| 同一路径从 6 秒重启 seek | pass，剩余输出 2 秒、drop_frames=0 | 另一个 seek 点 |
| 合成 4K HEVC Main10 / PQ / BT.2020 重封装 | pass，2160p、输出 2.952 秒、PQ / BT.2020 保留 | 10-bit HDR 直通标签，不是 HDR→SDR |

样本 SHA256、流规格、每条生产命令、耗时、输出时长与限制见 `hardware-evidence.json`。它记录 `-allow_sw 0`，但没有特权 GPU 利用率采样，不能把 ffmpeg 报告的零丢帧推广成所有设备负载下 <1%。

失败与边界同样保留：

- 本机 stock `scale_vt` 存在，但不支持仓库全 GPU 命令要求的 `format=` 参数。实跑全 GPU 路径报 `Error applying option 'format' to filter 'scale_vt': Option not found`；没有改生产命令来让它假通过。随后只验证保守能力下的 hwdownload / 软件缩放桥接路径。
- 本机没有 `tonemap_videotoolbox` / `tonemapx` / `zscale`，不能验收生产 HDR→SDR 链。不能用“仍可编码出画”当正确色调映射。
- 首次合成器只写 codec 色彩选项时，样本没有完整 PQ 标签；已拒绝该样本。最终使用帧级 `format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc` 与 libx265 生成，ffprobe 确认实际 Main10、PQ、BT.2020 后才测试。源样本生成使用 CPU 不代表产品转码使用 CPU。
- 没有在真实 iPhone / Safari 中完成播放、全屏、ASS/SRT/外挂字幕、续播 / 下一集 / 缩略图走查。

另有真实 FFmpeg / ffprobe 自动化 10/10 通过，覆盖软件转码、hvc1、关键帧、seek 与音频等；它们没有上述 Linux GPU，不能补齐下表。

## 仓库技能要求的矩阵与最低证据

`.claude/skills/release/SKILL.md` 第七节原文：“凡是改了 services/playback/（尤其 ffmpeg_args.py / hwprobe.py）或换了 ffmpeg 版本，发版前按下表逐项过一遍。”

| 后端 / 场景 | 当前证据 | 仍需的执行 |
|---|---|---|
| Intel VAAPI | 参数单测；#1263 有修前 NAS 复现，无修后记录 | 同一真实 Intel GPU 上的自检、HEVC+DTS 音频单转、4K HDR 全 GPU 转码 / HDR→SDR、多点 seek / 补片重启、实际 GPU 活动、分片 / 掉帧 |
| Intel QSV | 参数单测 | 同上；与 VAAPI 可在同一已授权 Intel 机器上分别测，不能把 VAAPI 结果自动算 QSV |
| NVIDIA NVENC | 参数单测 | 对应真实 NVIDIA GPU 与正确 FFmpeg / 驱动；不能从 Apple / Intel 推断 |
| AMD VAAPI | 参数单测 | 对应真实 AMD GPU 与驱动 |
| 无显卡软件兜底 | 软件 FFmpeg 10 项；部分合成封装 | 技能要求的 HDR 明确拒绝与完整播放器人工走查仍未逐项关闭 |
| iPhone / Safari / 字幕 / 续播等 | 浏览器更新回退 E2E，与播放真机不同 | 原生 HLS 全屏、HEVC hvc1 不黑屏、内封 ASS/SRT/外挂、下一集 / 续播 / 缩略图 |

当前最关键的是 `ffmpeg_args.py` 相对 v0.50.0 的 **+12/-4**：`-noautoscale` 从只对 `VT_GPU` 生效，扩到 VAAPI / QSV / NVENC 全 GPU 链。#1263 原 NAS 发生的 HEVC HDR seek 补片 218 / auto_scale 错误必须获得修后证据；代码 / 单元断言正确不等于驱动链路真能跑。

## 不用私有媒体的可执行补测任务

优先把任务送到**用户已经授权的、先前 #1263 所在 NAS 会话 / 代理**，不需要给技术会话任何密码或新远程授权。

1. 先只读返回：OS / CPU / GPU 型号、DRM render node 与驱动、现有 FFmpeg 版本、对应 encoders / hwaccels / tone-map filters。只用应用实际使用的 FFmpeg；本机 stock scale_vt 已证明“同名滤镜”不等于所需契约。
2. 在临时目录生成 HEVC+DTS 测试图 / 音调与 4K 10-bit PQ / BT.2020 测试图（可用 libx265、少量线程、短片；不读媒体库）。ffprobe 先核实际编码、位深与色彩标签。
3. 不部署服务、不连数据库。使用固定候选 SHA 的命令生成器直接生成 / 执行 HLS 命令；对应后端必须在自检为可用，硬件帧输出 / 硬件编码必须成立，不能退软件后仍记 GPU pass。
4. 对源在开头、1/3、2/3、靠近结尾处分别重启 seek / 补片命令；核命令中的硬件滤镜与 `-noautoscale`，逐段 ffprobe / 解码检查首帧关键帧、有效时间戳与连续输出。为覆盖滤镜图重建，可另合成分辨率 / 色彩元数据变化的流；这比只做一次平稳编码更贴近原故障。
5. 记录原始 argv、退出码、stderr / progress、分片序列、帧数 / drop_frames、GPU 活动（现有 `intel_gpu_top` / `nvidia-smi` / `radeontop` 只读采样）、版本 / 驱动 / 候选 SHA。硬件链须无 218 / `auto_scale_0` 失败，HDR→SDR 应实际输出正确 BT.709；不能仅检查“文件非空”。
6. 将这些证据交独立审查，再关闭适用的矩阵项。后端 / 真机未验的项继续明确写 pending；本次不能宣称全部硬件均已验证。

最小用户帮助：**指定已有 NAS 代理 / Hermesh 项目地址，或让已有会话执行上述只读库存和合成验收。无需私有影片、新凭据、生产部署或数据库变更。** 若某种 GPU 确实没有现有测试机器，维护者需要明确决定可交付范围 / 例外，而不是由技术会话擅自放行。

## 无相应硬件时的发布策略论证

- **仅删掉 changelog 的未验证后端或加“未测”说明，不关闭 P1。** 实际代码仍改变这三条硬件链，只改说明不能代替测试。
- **禁用三种后端或强制软件转码不采用。** 这会改变既有设备的性能与可用性，可能增加 NAS 负载，属于实质产品决策，不能借发版准备擅做。
- **临时排除 #1263 在技术上可局部构造，但没有执行。** 它仅改 `ffmpeg_args.py` 一个条件块（+12/-4）及 78 行参数测试；若维护者选择通过新审查 PR 收回这部分，需同步处理对应测试与双语说明，明确 v0.50.0 已知 seek 问题仍存在。不能偷偷改归档、让 tag / SHA 与分发代码不同，也不能擅自 revert 他人合并代码。
- **排除 #1263 也不是技能第七节的自动豁免。** 本版还有已看判定 / 字幕等 playback 改动，须独立审查重新核定硬件风险与人工门禁，维护者明确决定才可执行。当前优先级仍是使用已有 NAS 做无私有媒体的补测，保持已合入修复。
- 若没有任何已授权相应设备且没有明确的维护者处理意见，服务器保持未触发状态；不得为了完成“发新版”而把未执行项写通过。客户端 / TestFlight 后续阶段也不能用来替代服务器发布成功。
