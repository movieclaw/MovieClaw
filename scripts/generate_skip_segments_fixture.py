"""重建跳片头回归媒体和真实指纹（不使用生产片库）。

运行示例：python scripts/generate_skip_segments_fixture.py --output data/skip-segments-check
需要 numpy，以及支持 chromaprint 的 ffmpeg；可用 --encoder 指定另一份视频编码器。
三集的非重复内容使用独立乐音序列，重复内容按剪辑清单写入，再编码为 H.264/AAC。
指纹从最终 MP4 解码提取，预期区间来自剪辑清单，与识别算法的输出无关。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import wave
from pathlib import Path

import numpy as np

RATE = 22050
DURATION = 960
# 名称、开始秒、结束秒、音频种子、视频色块。紫色是较长的重复配乐剧情，不是片尾。
SEGMENTS = [
    ("ad", 5, 30, 10, "yellow"),
    ("intro", 65, 135, 20, "blue"),
    ("early_ad", 180, 210, 30, "orange"),
    ("reused_scene", 755, 825, 40, "purple"),
    ("outro", 920, 960, 50, "red"),
]


def music(seed: int, seconds: int) -> np.ndarray:
    """每半秒变化的三声部乐音，含泛音和淡入淡出；直接生成 PCM，不拼接指纹。"""
    rng = np.random.default_rng(seed)
    t = np.arange(RATE // 2) / RATE
    envelope = np.minimum(t / 0.02, 1) * np.minimum((0.5 - t) / 0.03, 1)
    chunks = []
    for _ in range(seconds * 2):
        notes = rng.choice(np.arange(45, 85), 3, replace=False)
        chord = np.zeros_like(t)
        for note in notes:
            f = 440 * 2 ** ((int(note) - 69) / 12)
            chord += sum(np.sin(2 * np.pi * f * harmonic * t) / harmonic for harmonic in (1, 2, 3))
        chunks.append((chord * envelope * 2400).astype("<i2"))
    return np.concatenate(chunks)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("data/skip-segments-check"))
    parser.add_argument("--ffmpeg", default="ffmpeg", help="支持 chromaprint 的 ffmpeg")
    parser.add_argument("--encoder", default="ffmpeg", help="用于生成 H.264/AAC 视频的 ffmpeg")
    parser.add_argument("--scenario", choices=["aligned", "shifted", "unique"], default="aligned")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    manifest = {
        "duration": DURATION,
        "sample_rate": RATE,
        "scenario": args.scenario,
        "fingerprinter": subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[
            0
        ],
        "episodes": [],
    }
    arrays = {}
    for n in range(1, 4):
        segments = []
        for name, start, end, seed, color in SEGMENTS:
            if args.scenario == "shifted" and start < 240:
                start, end = start + 7 * n, end + 7 * n
            if args.scenario == "unique":
                if name == "ad":
                    seed += n  # 每集不同的广告不应识别
                elif name == "early_ad":
                    end = start + 8  # 同一段但只有 8 秒，不到识别门槛
            segments.append((name, start, end, seed, color))
        audio = music(1000 + n, DURATION)
        for _, start, end, seed, _ in segments:
            audio[start * RATE : end * RATE] = music(seed, end - start)
        wav = root / f"episode-{n}.wav"
        with wave.open(str(wav), "wb") as out:
            out.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            out.writeframes(audio.tobytes())
        path = root / f"episode-{n}.mp4"
        filters = [
            f"drawbox=x=0:y=0:w=iw:h=ih:color={color}:t=fill:enable='between(t,{a},{b - 0.01})'"
            for _, a, b, _, color in segments
        ]
        subprocess.run(
            [
                args.encoder,
                "-v",
                "error",
                "-nostdin",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"color=c=black:s=320x180:r=2:d={DURATION}",
                "-i",
                str(wav),
                "-vf",
                ",".join(filters),
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-crf",
                "32",
                "-c:a",
                "aac",
                "-b:a",
                "64k",
                "-t",
                str(DURATION),
                str(path),
            ],
            check=True,
        )
        wav.unlink()
        # 与生产提取命令一致；窗口按剪辑总长显式给出，避免测试跟着算法错误一起变。
        for name, start in (("intro", 0), ("outro", 720)):
            args_window = [args.ffmpeg, "-nostdin", "-v", "error"]
            if start:
                args_window += ["-ss", str(start)]
            raw = subprocess.check_output(
                args_window
                + [
                    "-i",
                    str(path),
                    "-t",
                    "240",
                    "-map",
                    "0:a:0",
                    "-ac",
                    "2",
                    "-f",
                    "chromaprint",
                    "-fp_format",
                    "raw",
                    "-",
                ]
            )
            arrays[f"{n}_{name}"] = np.frombuffer(raw, dtype="<u4").copy()
        manifest["episodes"].append(
            {
                "file": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "episode": n,
                "segments": [{"name": name, "start": a, "end": b} for name, a, b, _, _ in segments],
            }
        )
        print(f"已生成并提取 {path.name}", flush=True)
    np.savez_compressed(root / "fingerprints.npz", **arrays)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
