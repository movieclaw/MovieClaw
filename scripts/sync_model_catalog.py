#!/usr/bin/env python3
"""同步公共模型目录快照（docs/design/llm-model-catalog.md §9.1）。

下载 https://models.dev/api.json，只取需要的服务商、需要的字段，写到
src/movieclaw_llm/providers/catalog/：每家一个 <catalog_id>.json，外加全部服务商
的 _index.json（兼容端点按地址识别用）。打印变化报告：新增/删除的模型、变化的
参数，以及预设 yaml 修正里与公共目录一致（可删）或冲突的字段。

用法：
    python scripts/sync_model_catalog.py                 # 下载并写快照
    python scripts/sync_model_catalog.py --input api.json  # 用本地文件
    python scripts/sync_model_catalog.py --report report.md  # 报告另存一份（每周 Action 用）

上游许可：models.dev 以 MIT 许可发布（Copyright (c) 2025 models.dev）。
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from movieclaw_llm.catalog import (  # noqa: E402
    BORROW_SOURCES,
    explicit_fields,
    project_catalog,
    provider_index,
    public_model_fields,
)
from movieclaw_llm.models import ModelInfo  # noqa: E402
from movieclaw_llm.providers import list_presets  # noqa: E402

URL = "https://models.dev/api.json"
OUT = ROOT / "src/movieclaw_llm/providers/catalog"
LICENSE = "models.dev, MIT License, Copyright (c) 2025 models.dev"

#: 预设与借用源之外，随包收录的常见 OpenAI 兼容端点
EXTRA_SOURCES = ("openrouter", "siliconflow-cn", "volcengine", "stepfun", "ollama-cloud")

_COMPARED = (
    "context_window",
    "max_output_tokens",
    "max_input_tokens",
    "modalities",
    "supports_tools",
    "supports_thinking",
    "thinking_control",
    "max_thinking_tokens",
)


def snapshot_ids() -> list[str]:
    ids = {p.catalog_id for p in list_presets() if p.catalog_id}
    return sorted(ids | set(BORROW_SOURCES) | set(EXTRA_SOURCES))


def load(path: str | None) -> dict:
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    request = urllib.request.Request(URL, headers={"User-Agent": "movieclaw-catalog-sync"})
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 -- 固定 HTTPS 地址
        return json.loads(response.read())


def diff_models(old: dict, new: dict) -> list[str]:
    lines: list[str] = []
    for cid in sorted(set(old) | set(new)):
        before = (old.get(cid) or {}).get("models", {})
        after = (new.get(cid) or {}).get("models", {})
        added = sorted(set(after) - set(before))
        removed = sorted(set(before) - set(after))
        changed = sorted(m for m in set(before) & set(after) if before[m] != after[m])
        if added:
            lines.append(f"- `{cid}` 新增：{', '.join(added)}")
        if removed:
            lines.append(f"- `{cid}` **删除**：{', '.join(removed)}")
        if changed:
            lines.append(f"- `{cid}` 参数变化：{', '.join(changed)}")
    return lines


def correction_report(projected: dict) -> list[str]:
    """预设 yaml 修正与公共目录逐字段比较：一致的可删，冲突的要人看。"""
    lines: list[str] = []
    for preset in list_presets():
        models = (projected.get(preset.catalog_id or "") or {}).get("models", {})
        for model in preset.models:
            raw = models.get(model.id)
            if raw is None:
                continue
            public = public_model_fields(raw, preset.thinking_prefer, preset.thinking_off_body)
            ours = explicit_fields(model)
            same, conflict = [], []
            for field in _COMPARED:
                if field not in ours or field not in public:
                    continue
                # 统一过一遍模型校验再比，嵌套对象的省略字段与默认值视为相同
                a = getattr(ModelInfo(id=model.id, **{field: ours[field]}), field)
                b = getattr(ModelInfo(id=model.id, **{field: public[field]}), field)
                (same if a == b else conflict).append(field)
            if same or conflict:
                parts = []
                if same:
                    parts.append(f"一致可删 {', '.join(same)}")
                if conflict:
                    parts.append(f"冲突 {', '.join(conflict)}")
                lines.append(f"- `{preset.id}/{model.id}`：{'；'.join(parts)}")
    return lines


def write_json(path: Path, data: object) -> None:
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", help="本地 api.json（默认下载）")
    parser.add_argument("--report", help="变化报告另存为 Markdown 文件")
    args = parser.parse_args()

    api = load(args.input)
    projected = project_catalog(api, snapshot_ids())
    fetched_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    old: dict = {}
    for path in OUT.glob("*.json"):
        if not path.name.startswith("_"):
            old[path.stem] = json.loads(path.read_text(encoding="utf-8"))

    OUT.mkdir(parents=True, exist_ok=True)
    changed = False
    for cid, data in projected.items():
        if (old.get(cid) or {}).get("models") != data["models"]:
            changed = True
            write_json(OUT / f"{cid}.json", {**data, "fetched_at": fetched_at, "license": LICENSE})
    for cid in set(old) - set(projected):
        (OUT / f"{cid}.json").unlink()
        changed = True
    write_json(OUT / "_index.json", provider_index(api))

    changes = diff_models(old, projected)
    report = [
        "## 模型目录变化",
        *(changes or ["- 无"]),
        "",
        "## 预设修正与公共目录对照",
        *(correction_report(projected) or ["- 无"]),
    ]
    text = "\n".join(report) + "\n"
    print(text)
    if args.report:
        Path(args.report).write_text(text, encoding="utf-8")
    print("快照有变化" if changed else "快照无变化", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
