"""画面文字识别（movieclaw_playback.ocr）。

模型文件不进仓库（随镜像发布）：本机或 CI 没有模型时，真实识别的用例自动跳过，
其余用例只测不依赖模型的部分。
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageDraw, ImageFont

from movieclaw_playback import ocr


def test_components_box_each_blob() -> None:
    binary = np.zeros((40, 80), dtype=bool)
    binary[5:10, 10:30] = True  # 一行字
    binary[20:26, 50:75] = True  # 另一行
    boxes = sorted(ocr._components(binary))
    assert boxes == [(5, 10, 10, 30), (20, 50, 26, 75)]


def test_missing_models_degrade_to_none(tmp_path) -> None:
    assert ocr.OcrEngine.load(tmp_path) is None
    (tmp_path / ocr.DET_MODEL).write_bytes(b"not a model")
    (tmp_path / ocr.REC_MODEL).write_bytes(b"not a model")
    assert ocr.OcrEngine.load(tmp_path) is None


def _model_dir() -> Path | None:
    for candidate in (os.environ.get("MOVIECLAW_OCR_DIR"), "data/models/ppocr"):
        if candidate and (Path(candidate) / ocr.DET_MODEL).is_file():
            return Path(candidate)
    return None


def _font() -> ImageFont.FreeTypeFont | None:
    for path in (
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        if Path(path).is_file():
            return ImageFont.truetype(path, 36)
    return None


@pytest.mark.skipif(_model_dir() is None or _font() is None, reason="本机没有 OCR 模型或字体")
def test_reads_credit_lines_on_black() -> None:
    img = Image.new("RGB", (960, 540), (5, 5, 5))
    draw = ImageDraw.Draw(img)
    draw.text((300, 200), "Executive Producer", fill=(235, 235, 235), font=_font())
    draw.text((330, 280), "JOHN SMITH", fill=(235, 235, 235), font=_font())
    engine = ocr.OcrEngine.load(_model_dir())
    assert engine is not None
    texts = [line.text for line in engine.read(np.asarray(img))]
    assert any("Executive" in t for t in texts)
    assert any("SMITH" in t for t in texts)
