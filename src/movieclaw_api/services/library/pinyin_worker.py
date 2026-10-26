"""拼音计算本体：主进程按需拉起的短命子进程，也是主进程的兜底实现。

pypinyin 的词组词库导入即常驻约 50MB，所以只在这里导入：主进程把一批没见过的
名字交给 ``python pinyin_worker.py``（按文件路径运行，不导入 movieclaw 包，冷启动
约 0.1 秒），算完即退。协议：标准输入一个 JSON ``{"sort": [...], "syllables": [...]}``，
标准输出同形状的结果。

两个函数与改造前 sort_key / search_matching 里的调用逐字相同，结果不变。
"""

from __future__ import annotations

import json
import os
import sys


def sort_pinyin(text: str) -> str:
    """标题排序用的整串拼音（逐字转拼音后拼接，非中文片段原样转小写）。"""
    from pypinyin import Style, lazy_pinyin

    return "".join(lazy_pinyin(text, style=Style.NORMAL, errors=lambda item: item.lower())).lower()


def syllables(text: str) -> list[str]:
    """逐字读音，与 text 逐字对齐（非中文字符原样占一位）。"""
    from pypinyin import Style, pinyin

    return [
        part[0]
        for part in pinyin(
            text, style=Style.NORMAL, heteronym=False, errors=lambda value: list(value)
        )
    ]


def compute(request: dict) -> dict:
    return {
        "sort": [sort_pinyin(text) for text in request.get("sort", [])],
        "syllables": [syllables(text) for text in request.get("syllables", [])],
    }


if __name__ == "__main__":
    if "--background" in sys.argv:
        # 启动补算是后台活：别和播放、转码抢 CPU
        os.nice(10)
    json.dump(compute(json.load(sys.stdin)), sys.stdout, ensure_ascii=False)
