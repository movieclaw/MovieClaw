"""转码器应用外壳（app/）的单元测试：纯标准库逻辑层，不需要显卡、GUI，CI 在 Linux 上跑。

托盘与窗口（tray.py / window.py）是薄界面，不在这里测——它们消费的每一个状态与动作
都在 model 的测试里覆盖。
"""

from __future__ import annotations

import sys
from pathlib import Path

WORKER_DIR = Path(__file__).resolve().parents[2] / "windows" / "MovieClawTranscoder"
for path in (str(WORKER_DIR), str(WORKER_DIR / "app"), str(Path(__file__).resolve().parent)):
    if path not in sys.path:
        sys.path.insert(0, path)
