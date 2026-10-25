# Windows 转码器 0.1.0（中文首发草稿）

把 NAS 的转码交给 Windows 电脑上的 NVIDIA 显卡。

- 安装后可发现局域网中的 MovieClaw，用管理员账号批准配对即可连接；首次运行会下载并校验所需的 jellyfin-ffmpeg。
- 提供托盘、重连、重新配对和开机自启控制，也可使用无界面的命令行模式。
- 需要 Windows 10/11、支持 NVENC 的 NVIDIA 显卡与合适的驱动。建议与服务器 0.43.0 配套，按实际检测结果承接转码任务；不支持蓝光原盘与 MPEG-TS 分片任务。
- 安装向导默认勾选开机自启，可随时关闭；静默安装不会自动启动或写入自启。

此文档只是首发草稿。尚无独立 tag/Release 流水线，不能用 windows-v0.1.2（播放客户端）或 transcoder-v0.33.1（Mac 转码器）发布。建议新命名 windows-transcoder-v0.1.0，需先补齐下载清单识别、发布渠道和 Windows 安装验收。
