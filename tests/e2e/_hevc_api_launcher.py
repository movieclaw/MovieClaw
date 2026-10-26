"""#1008 浏览器端到端专用的后端启动器：在 ``_api_launcher`` 之上把硬件自检结论写成「VAAPI 可用、
HEVC 也真编通过」。测试机没有显卡，VAAPI 命令由 PATH 里包的 ffmpeg 换成软件编码
（test_hevc_transcode_browser.py），其余全是真代码。
"""

from __future__ import annotations

import runpy
from pathlib import Path

from movieclaw_api.services.playback import hwprobe
from movieclaw_api.services.playback.ffmpeg_args import register_hevc_encoder

hwprobe._cache = [
    hwprobe.HwBackendStatus(
        name="vaapi",
        label=hwprobe.BACKEND_LABELS["vaapi"],
        available=True,
        detail="e2e 注入：自检通过，HEVC 编码也已验证",
    )
]
register_hevc_encoder("vaapi", ())

runpy.run_path(str(Path(__file__).with_name("_api_launcher.py")), run_name="__main__")
