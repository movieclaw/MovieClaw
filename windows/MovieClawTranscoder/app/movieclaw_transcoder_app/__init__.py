"""MovieClaw 转码器（Windows）的应用外壳：托盘 + 窗口 + 转码内核，同一个进程。

转码与协议都在 ``movieclaw_transcoder`` 包里（纯标准库、命令行可独立运行）；这一层
只做「打开就能配对」的编排：局域网里找 NAS、设备授权配对、首次运行从 Jellyfin 官方
下载 ffmpeg，然后把转码内核跑起来。与命令行版共用 ``%APPDATA%\\MovieClawTranscoder``
下的同一份配置与日志，单实例互斥锁也是同一把——同一台电脑里两者只能跑一个。
"""

__version__ = "0.1.0"


def main(argv: list[str] | None = None) -> int:
    """应用入口（延迟导入：``__main__`` 里的模块级依赖只在真要跑界面时才拉）。"""
    from .__main__ import main as run

    return run(argv)
