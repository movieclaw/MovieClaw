"""ffmpeg 的替身（测试专用）：Job 的参数照 NAS 下发的样子传进来，这里按 ``--mode`` 演一遍。

- ``ok``：往输出文件里写 init 与 ``--fragments`` 个 0.5 秒的片段（每 2 秒一个同步帧），边写边打印
  ``-progress`` 风格的进度，最后 ``progress=end``、退出码 0；
- ``slow``：同上但不收尾，一直写到被杀（最多 30 秒）；
- ``progress-once``：只写一条短进度后保持管道打开，直到被停止（最多 30 秒）；
- ``fail``：往 stderr 打一堆行，退出码 3；
- ``hang``：不出任何进度（只往管道写空行，父进程没了就会写失败而退出）；
- ``garbage``：写完 init 再写一个长度不合理的盒头，然后像 hang 一样不动；
- ``plain``：不碰输出，把收到的参数原样记进 ``--dump`` 文件，退出码 0。

最后一个参数是输出：``tcp://127.0.0.1:端口``（渐进式任务里 Job 把 NAS 的 stream.mp4 地址换成它）
或本机文件。
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fmp4 import fragment, init_segment  # noqa: E402


class Output:
    """输出：tcp:// 回环口或本机文件，都按字节写。"""

    def __init__(self, target: str) -> None:
        self._socket = None
        if target.startswith("tcp://"):
            host, _, port = target[len("tcp://") :].partition(":")
            self._socket = socket.create_connection((host, int(port)))
            self._file = self._socket.makefile("wb")
        else:
            self._file = open(target, "ab")  # noqa: SIM115

    def write(self, data: bytes) -> None:
        self._file.write(data)

    def flush(self) -> None:
        self._file.flush()

    def __enter__(self) -> Output:
        return self

    def __exit__(self, *_exc: object) -> None:
        self._file.close()
        if self._socket is not None:
            self._socket.close()


def progress(out_time_ms: int, *, end: bool = False) -> None:
    sys.stdout.write(
        f"out_time_us={out_time_ms * 1000}\nspeed=1.5x\nprogress={'end' if end else 'continue'}\n"
    )
    sys.stdout.flush()


def idle(seconds: float) -> None:
    """不出进度地等：空行不算进度，但父进程没了的话写管道会失败，替身随之退出。"""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        sys.stdout.write("\n")
        sys.stdout.flush()
        time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", default="ok")
    parser.add_argument("--fragments", type=int, default=8)
    parser.add_argument("--delay", type=float, default=0.02)
    parser.add_argument("--dump")
    parser.add_argument("-progress")
    parser.add_argument("output")
    args = parser.parse_args()

    if args.mode == "plain":
        Path(args.dump).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
        progress(1000, end=True)
        return 0
    if args.mode == "fail":
        for index in range(60):
            print(f"error line {index}", file=sys.stderr)
        return 3
    if args.mode == "hang":
        idle(20)
        return 0

    with Output(args.output) as out:
        out.write(init_segment(with_audio=False))
        out.flush()
        if args.mode == "garbage":
            out.write(b"\x7f\xff\xff\xffjunk")
            out.flush()
            idle(20)
            return 0
        deadline = time.monotonic() + 30
        index = 0
        while time.monotonic() < deadline and (args.mode == "slow" or index < args.fragments):
            at = index * 500
            out.write(fragment(start_ms=at, sync=at % 2000 == 0))
            out.flush()
            progress(at + 500)
            if args.mode == "progress-once":
                time.sleep(30)
                return 0
            time.sleep(args.delay)
            index += 1
        if args.mode == "ok":
            progress(index * 500, end=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, OSError):
        sys.exit(1)
