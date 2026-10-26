"""Windows 转码器单元测试：把包目录放进 sys.path。程序是纯标准库，不需要显卡、也不需要 ffmpeg。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "windows" / "MovieClawTranscoder"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
