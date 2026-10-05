"""画面文字识别：PP-OCRv4 的 ONNX 模型，只用 onnxruntime + numpy + Pillow。

设计见 docs/design/skip-intro.md §2.12。

片头片尾识别用它读画面上的字：演职员表（片尾从哪开始、到哪结束）、「广告」角标、
「下集预告」字样。音频只能告诉我们「这段声音每集都有」，分不清画面上是演职员表还是
剧情，文字是最直接的证据。

为什么自己写推理而不引 RapidOCR / PaddleOCR 的 Python 包：它们要拖 opencv、pyclipper、
shapely 等一串二进制依赖，而我们只需要横排文字：

- **检测**（DBNet）：概率图二值化、膨胀，连通域取外接框，按 PP-OCR 的 unclip 公式外扩。
  连通域在 1/4 分辨率的格子图上 BFS（文字像素稀疏，纯 Python 也够快）；
- **识别**（SVTR-LCNet）：按框裁切、等比缩放到高 48，CTC 贪心解码，字表在模型元数据里。

不做方向分类、不做旋转框：视频画面上的字几乎都是横排。模型文件随镜像发布
（Dockerfile 的 ppocr-model 阶段，``MOVIECLAW_OCR_DIR`` 指过去）；缺失或加载失败时
``OcrEngine.load`` 返回 None，调用方退回纯音频结果，不影响其他功能。

NAS（Ryzen V1500B，单线程）实测：960 宽的一帧 0.8～1.5 秒；Mac M 系列约 0.4 秒。
满屏演职员表（40～110 个文字框）一帧 2～11 秒，几乎全花在识别上。

服务里不在服务进程内推理：``python -m movieclaw_playback.ocr <模型目录>`` 起常驻的低优先级
工作进程（``_main``），片头片尾识别按并发路数起几个（``skip_segments._OcrPool``）。
推理前后的 numpy / 纯 Python 处理会占 GIL，放在服务进程里会拖慢同时在跑的接口。
"""

from __future__ import annotations

import json
import logging
import os
import sys
from collections import deque
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

logger = logging.getLogger("movieclaw_playback.ocr")

DET_MODEL = "ch_PP-OCRv4_det_infer.onnx"
REC_MODEL = "ch_PP-OCRv4_rec_infer.onnx"

#: 检测输入的短边像素：544 对 960 宽的画面足够，736（PP-OCR 默认）慢一倍、收益不明显
DET_SIDE = 544
#: 概率图二值化阈值、框内平均概率门槛、外扩系数：沿用 PP-OCR 默认值
_DET_THRESH = 0.3
_BOX_THRESH = 0.5
_UNCLIP = 1.6
#: 识别输入高度与批大小
_REC_HEIGHT = 48
_REC_BATCH = 8


@dataclass(frozen=True)
class TextLine:
    """识别出的一行字。``box`` 是归一化坐标（0～1，相对画面宽高），与分辨率无关。"""

    text: str
    score: float
    box: tuple[float, float, float, float]  # x0, y0, x1, y1


class OcrEngine:
    """PP-OCR 检测 + 识别。一个进程一份（模型加载约 0.3 秒、常驻约 60 MB）。"""

    def __init__(self, model_dir: Path, threads: int = 1):
        import onnxruntime as ort

        opts = ort.SessionOptions()
        # 单线程：识别是后台作业，不该抢播放与转码的 CPU
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = 1
        providers = ["CPUExecutionProvider"]
        self._det = ort.InferenceSession(str(model_dir / DET_MODEL), opts, providers=providers)
        self._rec = ort.InferenceSession(str(model_dir / REC_MODEL), opts, providers=providers)
        chars = self._rec.get_modelmeta().custom_metadata_map["character"].splitlines()
        # 下标 0 是 CTC 空白，最后一类是空格（PP-OCR 的 use_space_char）
        self._chars = ["", *chars, " "]

    @classmethod
    def load(cls, model_dir: str | Path) -> OcrEngine | None:
        """加载模型；文件缺失或加载失败返回 None（调用方退回纯音频结果）。"""
        path = Path(model_dir)
        if not (path / DET_MODEL).is_file() or not (path / REC_MODEL).is_file():
            return None
        try:
            return cls(path)
        except Exception as exc:  # noqa: BLE001 —— 模型损坏、onnxruntime 不可用都只降级
            logger.warning("画面文字识别模型加载失败，片头片尾识别只用声音：%s", exc)
            return None

    def read(self, img: np.ndarray, side: int = DET_SIDE, min_score: float = 0.6) -> list[TextLine]:
        """整帧识别：RGB uint8 数组 → 文字行（按置信度过滤）。"""
        h, w = img.shape[:2]
        lines = []
        for text, score, (x0, y0, x1, y1) in self._recognize(img, self._detect(img, side)):
            if score >= min_score:
                lines.append(TextLine(text, score, (x0 / w, y0 / h, x1 / w, y1 / h)))
        return lines

    def read_corners(self, img: np.ndarray, min_score: float = 0.6) -> list[str]:
        """四个角放大两倍再识别，返回读到的字：「广告」角标只有画面宽度的 3%、半透明灰底，
        整帧检测会漏（平台标识在右下角，华语剧 D的冠名广告在右上）。NAS 上约 0.6 秒。"""
        h, w = img.shape[:2]
        texts = []
        for x0, y0, x1, y1 in (
            (0, 0, 0.2, 0.3),
            (0.8, 0, 1, 0.3),
            (0, 0.8, 0.2, 1),
            (0.8, 0.8, 1, 1),
        ):
            crop = img[int(y0 * h) : int(y1 * h), int(x0 * w) : int(x1 * w)]
            if crop.shape[0] < 8 or crop.shape[1] < 8:
                continue
            up = Image.fromarray(crop).resize((crop.shape[1] * 2, crop.shape[0] * 2), Image.BICUBIC)
            arr = np.asarray(up)
            texts += [
                line.text for line in self.read(arr, side=min(arr.shape[:2]), min_score=min_score)
            ]
        return texts

    # ------------------------------------------------------------------ 检测
    def _detect(self, img: np.ndarray, side: int) -> list[tuple[int, int, int, int]]:
        h, w = img.shape[:2]
        scale = side / min(h, w)
        nh = max(32, int(round(h * scale / 32)) * 32)
        nw = max(32, int(round(w * scale / 32)) * 32)
        x = np.asarray(Image.fromarray(img).resize((nw, nh), Image.BILINEAR), dtype=np.float32)
        x = ((x / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)[None]
        prob = self._det.run(None, {"x": x})[0][0, 0]
        binary = prob > _DET_THRESH
        # 2×2 膨胀（PP-OCR 的 use_dilation），把一个字里断开的笔画连起来
        binary[:-1] |= binary[1:]
        binary[:, :-1] |= binary[:, 1:]
        boxes = []
        for y0, x0, y1, x1 in _components(binary):
            if y1 - y0 < 3 or x1 - x0 < 3:
                continue
            if float(prob[y0:y1, x0:x1][binary[y0:y1, x0:x1]].mean()) < _BOX_THRESH:
                continue
            bw, bh = x1 - x0, y1 - y0
            d = bw * bh * _UNCLIP / (2 * (bw + bh))
            boxes.append(
                (
                    int(max(0.0, x0 - d) * w / nw),
                    int(max(0.0, y0 - d) * h / nh),
                    int(np.ceil(min(nw, x1 + d) * w / nw)),
                    int(np.ceil(min(nh, y1 + d) * h / nh)),
                )
            )
        return boxes

    # ------------------------------------------------------------------ 识别
    def _recognize(self, img: np.ndarray, boxes: list[tuple[int, int, int, int]]):
        crops = [
            (b, img[b[1] : b[3], b[0] : b[2]])
            for b in boxes
            if b[2] - b[0] >= 4 and b[3] - b[1] >= 4
        ]
        # 宽高比相近的放一批，补零少
        crops.sort(key=lambda c: c[1].shape[1] / c[1].shape[0])
        for i in range(0, len(crops), _REC_BATCH):
            group = crops[i : i + _REC_BATCH]
            ratio = max(320 / _REC_HEIGHT, max(c.shape[1] / c.shape[0] for _, c in group))
            width = int(np.ceil(_REC_HEIGHT * ratio))
            batch = np.zeros((len(group), 3, _REC_HEIGHT, width), dtype=np.float32)
            for k, (_, crop) in enumerate(group):
                cw = min(width, int(np.ceil(_REC_HEIGHT * crop.shape[1] / crop.shape[0])))
                resized = Image.fromarray(crop).resize((cw, _REC_HEIGHT), Image.BILINEAR)
                arr = np.asarray(resized, dtype=np.float32)
                batch[k, :, :, :cw] = ((arr / 255.0 - 0.5) / 0.5).transpose(2, 0, 1)
            prob = self._rec.run(None, {"x": batch})[0]
            best, conf = prob.argmax(axis=2), prob.max(axis=2)
            for k, (box, _) in enumerate(group):
                chars, scores, last = [], [], -1
                for t, j in enumerate(best[k].tolist()):
                    if j != last and j != 0:
                        chars.append(self._chars[j] if j < len(self._chars) else "")
                        scores.append(float(conf[k, t]))
                    last = j
                text = "".join(chars).strip()
                if text:
                    yield text, float(np.mean(scores)), box


def _components(binary: np.ndarray, step: int = 4) -> Iterator[tuple[int, int, int, int]]:
    """连通域外接框 (y0, x0, y1, x1)。

    按 ``step`` 降采样成「格子里有前景」，在格子图上 BFS，再回原图收紧。
    """
    h, w = binary.shape
    gh, gw = (h + step - 1) // step, (w + step - 1) // step
    padded = np.zeros((gh * step, gw * step), dtype=bool)
    padded[:h, :w] = binary
    grid = padded.reshape(gh, step, gw, step).any(axis=(1, 3))
    seen = np.zeros_like(grid)
    for sy, sx in zip(*(a.tolist() for a in np.nonzero(grid)), strict=True):
        if seen[sy, sx]:
            continue
        queue = deque([(sy, sx)])
        seen[sy, sx] = True
        y0 = y1 = sy
        x0 = x1 = sx
        while queue:
            y, x = queue.popleft()
            y0, y1, x0, x1 = min(y0, y), max(y1, y), min(x0, x), max(x1, x)
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < gh and 0 <= nx < gw and grid[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        top, bottom = y0 * step, min(h, (y1 + 1) * step)
        left, right = x0 * step, min(w, (x1 + 1) * step)
        sub = binary[top:bottom, left:right]
        rows = np.nonzero(sub.any(axis=1))[0]
        cols = np.nonzero(sub.any(axis=0))[0]
        if len(rows):
            yield (
                top + int(rows[0]),
                left + int(cols[0]),
                top + int(rows[-1]) + 1,
                left + int(cols[-1]) + 1,
            )


def _main() -> None:
    """工作进程入口：一行 JSON 头（``h`` ``w`` ``corners``）+ h×w×3 字节的 RGB 帧进，一行 JSON 出。

    出：``{"luma", "lines": [[文字, x0, y0, x1, y1], ...], "corners": [...] 或 null}``，
    识别出错时 ``{"error": 原因}``，进程继续服务下一帧。模型加载失败直接退出（退出码 2）。
    """
    if hasattr(os, "nice"):
        os.nice(10)  # 后台识别不抢播放与接口的 CPU
    engine = OcrEngine.load(sys.argv[1])
    if engine is None:
        sys.exit(2)
    stdin, stdout = sys.stdin.buffer, sys.stdout
    while head := stdin.readline():
        request = json.loads(head)
        h, w = int(request["h"]), int(request["w"])
        data = stdin.read(h * w * 3)
        if len(data) != h * w * 3:
            break  # 父进程走了
        try:
            img = np.frombuffer(data, dtype=np.uint8).reshape(h, w, 3)
            reply = {
                "luma": float(img.mean()),
                "lines": [[x.text, *x.box] for x in engine.read(img)],
                "corners": engine.read_corners(img) if request.get("corners") else None,
            }
        except Exception as exc:  # noqa: BLE001 —— 一帧出错只影响这一帧，由调用方退回声音结果
            reply = {"error": f"{type(exc).__name__}: {exc}"}
        stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
        stdout.flush()


if __name__ == "__main__":
    _main()
