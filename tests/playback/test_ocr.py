"""画面文字识别（movieclaw_playback.ocr）。

模型文件不进仓库（随镜像发布）：本机或 CI 没有模型时，真实识别的用例自动跳过，
其余用例只测不依赖模型的部分。
"""

from __future__ import annotations

import json
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


def test_dense_white_names_do_not_make_a_black_background_bright():
    img = np.full((200, 400, 3), 5, dtype=np.uint8)
    lines = []
    for y in range(20, 180, 20):
        img[y : y + 10, 30:370:2] = 220
        lines.append(ocr.TextLine("NAME", 1.0, (0.075, y / 200, 0.925, (y + 10) / 200)))
    assert img.mean() > 28
    assert ocr.frame_luma(img, lines) == pytest.approx(5)


def test_text_does_not_turn_bright_or_dim_story_into_black_credits():
    lines = [
        ocr.TextLine("NAME", 1.0, (0.4, y / 200, 0.6, (y + 5) / 200)) for y in range(20, 180, 20)
    ]
    for background in (27, 85, 230):
        img = np.full((200, 400, 3), background, dtype=np.uint8)
        for line in lines:
            _, y0, _, y1 = line.box
            img[int(y0 * 200) : int(y1 * 200), 160:240] = 220
        assert ocr.frame_luma(img, lines) == pytest.approx(float(img.mean()))


def test_oversized_text_boxes_cannot_hide_the_whole_picture():
    img = np.zeros((200, 400, 3), dtype=np.uint8)
    img[10:190] = 120
    lines = [ocr.TextLine("NAME", 1.0, (0, 0.05, 1, 0.95))] * 6
    assert ocr.frame_luma(img, lines) == pytest.approx(float(img.mean()))


def test_black_text_on_white_paper_is_not_removed_as_white_names():
    img = np.zeros((200, 400, 3), dtype=np.uint8)
    img[:, 150:250] = 220
    lines = []
    for y in range(20, 180, 20):
        img[y : y + 5, 160:240:3] = 0
        lines.append(ocr.TextLine("正文资料", 1.0, (0.4, y / 200, 0.6, (y + 5) / 200)))
    assert ocr.frame_luma(img, lines) == pytest.approx(float(img.mean()))


_BACKGROUND_FIXTURES = Path(__file__).parent / "fixtures/skip_segments"


@pytest.mark.parametrize(
    "case",
    json.loads((_BACKGROUND_FIXTURES / "nas-credit-backgrounds.json").read_text()),
    ids=lambda c: c["key"],
)
def test_real_dense_credits_and_book_page_backgrounds(case):
    with np.load(_BACKGROUND_FIXTURES / "nas-credit-backgrounds.npz") as data:
        img = data[case["key"]]
    lines = [ocr.TextLine(x[0], 1.0, tuple(x[1:])) for x in case["lines"]]
    assert img.mean() >= 28
    luma = ocr.frame_luma(img, lines)
    assert (luma < 28) == case["expected_dark"]
    if not case["expected_dark"]:
        assert luma == pytest.approx(float(img.mean()))


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


def _credits_frame() -> np.ndarray:
    img = Image.new("RGB", (960, 540), (5, 5, 5))
    draw = ImageDraw.Draw(img)
    draw.text((300, 200), "Executive Producer", fill=(235, 235, 235), font=_font())
    draw.text((20, 20), "AD", fill=(235, 235, 235), font=_font())
    return np.asarray(img)


@pytest.mark.skipif(_model_dir() is None or _font() is None, reason="本机没有 OCR 模型或字体")
def test_worker_process_reads_the_same_as_in_process_engine() -> None:
    """片头片尾识别把推理放进工作进程（skip_segments._OcrPool）：结果要和进程内逐字一致，
    进程用完放回池里复用，不每帧重起。"""
    import asyncio

    from movieclaw_api.services.library.skip_segments import _OcrPool

    img = _credits_frame()
    engine = ocr.OcrEngine.load(_model_dir())
    assert engine is not None
    expected = [(x.text, *x.box) for x in engine.read(img)]

    async def scenario():
        pool = _OcrPool(str(_model_dir()))
        try:
            first = await pool.recognize(img, True)
            pid = pool.idle[0].proc.pid
            second = await pool.recognize(img, False)
            return first, second, pid == pool.idle[0].proc.pid and len(pool.idle) == 1
        finally:
            await pool.close()

    (luma, lines, corners), (_, again, no_corners), reused = asyncio.run(scenario())
    assert lines == expected and any("Executive" in t for t, *_ in lines)
    assert luma == pytest.approx(float(img.mean()))
    assert corners == engine.read_corners(img)
    assert again == expected and no_corners is None
    assert reused, "第二帧应当复用同一个工作进程"


def test_worker_without_usable_models_fails_only_that_frame(tmp_path) -> None:
    """模型坏了：工作进程起不来，这一帧报错（调用方退回声音结果），池里不留坏进程。"""
    import asyncio

    from movieclaw_api.services.library.skip_segments import _OcrPool

    (tmp_path / ocr.DET_MODEL).write_bytes(b"not a model")
    (tmp_path / ocr.REC_MODEL).write_bytes(b"not a model")

    async def scenario():
        pool = _OcrPool(str(tmp_path))
        try:
            with pytest.raises(RuntimeError, match="文字识别进程退出了"):
                await pool.recognize(np.zeros((8, 8, 3), dtype=np.uint8), False)
            return len(pool.idle), len(pool.busy)
        finally:
            await pool.close()

    assert asyncio.run(scenario()) == (0, 0)
