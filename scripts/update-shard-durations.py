#!/usr/bin/env python3
"""从一次全量 pytest 的 JUnit 报告刷新 CI 分片用的各文件耗时记录。

CI 把 pytest 拆成几片并行（见 .github/workflows/ci.yml 与 tests/conftest.py 的
pytest_collection_modifyitems），按 tests/shard-durations.json 里各测试文件的
历史耗时装箱，让几片大致同时跑完。记录过时不会漏跑，只会让几片不均衡——
某一片明显比别的慢时跑一次本脚本即可：

    python -m pytest -m "not integration" -n auto --dist loadfile --junitxml=/tmp/junit.xml
    python scripts/update-shard-durations.py /tmp/junit.xml

只关心相对大小，本机与 CI 的绝对快慢不同不影响分片。
"""

from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

_TARGET = Path(__file__).resolve().parents[1] / "tests" / "shard-durations.json"


def file_of(classname: str) -> str:
    """JUnit 的 classname（tests.api.test_x 或 tests.api.test_x.TestCls）→ 文件路径。"""
    parts = classname.split(".")
    for index, part in enumerate(parts):
        if part.startswith("test_"):
            return "/".join(parts[: index + 1]) + ".py"
    return "/".join(parts) + ".py"


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    seconds: dict[str, float] = defaultdict(float)
    for case in ET.parse(argv[0]).getroot().iter("testcase"):
        seconds[file_of(case.get("classname", ""))] += float(case.get("time") or 0)
    durations = {path: round(value, 1) for path, value in sorted(seconds.items())}
    _TARGET.write_text(json.dumps(durations, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"已写入 {_TARGET}（{len(durations)} 个测试文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
