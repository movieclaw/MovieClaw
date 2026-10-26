"""MovieClaw 转码器（Windows）：NAS 的远程硬件转码 Worker，NVIDIA NVENC 后端。

与 macOS 转码器（``macos/MovieClawTranscoder``）说同一套控制协议
（docs/design/remote-transcode.md）：
连 ``/api/v1/transcode-worker/ws``，在 hello 里声明自己的 ffmpeg 能力，之后由 NAS 派单；
本机 ffmpeg 直接读 NAS 的签名源地址，产物按 HLS 分片栅格切好、分块回传 NAS。

纯标准库，没有第三方依赖；需要一份带 NVENC 与 CUDA 滤镜的 ffmpeg（推荐 jellyfin-ffmpeg）。
"""

__version__ = "0.1.0"

#: 与服务端 ``REMOTE_WORKER_PROTOCOL_VERSION`` 对齐（remote_worker.py）：两边不一致时
#: 服务端在握手里直接拒绝并说明原因。
PROTOCOL_VERSION = 1
