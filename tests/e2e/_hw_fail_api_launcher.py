"""issue #763 浏览器端到端专用的后端启动器：在 ``_api_launcher`` 之上只多一件事——
硬件自检结论直接写成「VAAPI 可用」。

现场是自检（一秒 H.264 编码）通过、真实转码命令起步即退出。测试机没有 VAAPI，
所以自检结论由这里注入，「起步即退出」由 PATH 里包了一层的 ffmpeg 模拟（见
test_hw_transcode_startup_failure_browser.py），其余全是真代码。
"""

from __future__ import annotations

import runpy
from pathlib import Path

from movieclaw_api.services.playback import hwprobe

hwprobe._cache = [
    hwprobe.HwBackendStatus(
        name="vaapi",
        label=hwprobe.BACKEND_LABELS["vaapi"],
        available=True,
        detail="e2e 注入：自检通过",
    )
]

runpy.run_path(str(Path(__file__).with_name("_api_launcher.py")), run_name="__main__")
