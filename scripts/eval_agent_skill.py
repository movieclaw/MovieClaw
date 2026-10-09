#!/usr/bin/env python3
"""对一台真实的 MovieClaw 服务器跑 Agent 技能的评测集（skill-creator 的 evals/evals.json 格式）。

每条评测开一个新会话、只发一轮，等 Agent 跑完后自动判定 ``checks``，并打印每条的工具调用、
读了技能里的哪些文件、最终回答，供人工按 ``expectations`` 复核。跑完删除评测会话、注销登录设备。

    MOVIECLAW_EVAL_USER=... MOVIECLAW_EVAL_PASS=... \\
      python scripts/eval_agent_skill.py src/movieclaw_agent/builtin-skills/movieclaw-plugin-dev \\
      --server http://192.168.1.10:3000 [--ids 1,4] [--concurrency 3] \\
      [--model kimi-k2.6] [--json out.json]

checks 支持：
- ``skill_read``：true = 必须读技能的 SKILL.md；false = 不该读（不需要插件的请求）；
- ``must_read_any``：必须读到其中至少一个技能内文件（相对技能目录）；
- ``must_mention_any``：回答里至少出现其中一个词；
- ``no_install``：没有安装 / 上传 / 批准插件包；
- ``no_scaffold``：没有生成骨架、没有往 plugins/ 写插件代码。
凭据只从环境变量读，不落盘。评测里 Agent 若在工作目录写了插件骨架，结尾会列出来，需要手动清理。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

INSTALLATION_ID = "movieclaw-skill-eval-runner"


class Api:
    def __init__(self, server: str) -> None:
        self.server = server.rstrip("/")
        self.token: str | None = None

    def call(self, method: str, path: str, body: Any = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.server + "/api/v1" + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            raise SystemExit(f"{method} {path} → {exc.code}: {exc.read().decode()[:300]}") from exc
        return json.loads(raw)["data"] if raw else None

    def login(self, user: str, password: str) -> None:
        client = {"kind": "macos", "installation_id": INSTALLATION_ID, "name": "技能评测"}
        self.token = self.call(
            "POST", "/auth/device/login", {"username": user, "password": password, "client": client}
        )["token"]

    def logout(self) -> None:
        self.call("DELETE", "/auth/devices/current")


def _text(content: Any) -> str:
    if isinstance(content, str):
        return content
    return "".join(p.get("text") or "" for p in content or [] if p.get("type") == "text")


def run_one(api: Api, case: dict, skill_dir: str, model: str | None, timeout: float) -> dict:
    body: dict[str, Any] = {"content": case["prompt"]}
    if model:
        body["model"] = model
    session_id = api.call("POST", "/sessions", body)["session_id"]
    deadline = time.monotonic() + timeout
    while True:
        time.sleep(5)
        detail = api.call("GET", f"/sessions/{session_id}")
        if not detail["session"]["running"] or time.monotonic() > deadline:
            break
    calls: list[tuple[str, dict]] = []
    answer: list[str] = []
    served = None
    for entry in detail["entries"]:
        message = entry.get("message") or {}
        if message.get("role") != "assistant":
            continue
        served = served or entry.get("model")
        for call in message.get("tool_calls") or []:
            fn = call.get("function") or call
            args = fn.get("arguments")
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {"raw": args}
            calls.append((fn.get("name") or "", args or {}))
        if _text(message.get("content")).strip():
            answer.append(_text(message["content"]).strip())
    api.call("DELETE", f"/sessions/{session_id}")
    return {
        "case": case,
        "calls": calls,
        "answer": "\n\n".join(answer),
        "model": served,
        "timed_out": detail["session"]["running"],
        "skill_dir": skill_dir,
    }


def _blob(args: dict) -> str:
    return json.dumps(args, ensure_ascii=False)


def judge(result: dict) -> list[tuple[str, bool, str]]:
    checks = result["case"].get("checks") or {}
    calls = result["calls"]
    marker = f"/{Path(result['skill_dir']).name}/"
    read_files = sorted(
        {
            str(args.get("path", "")).split(marker, 1)[1]
            for name, args in calls
            if name == "read" and marker in str(args.get("path", ""))
        }
    )
    result["skill_files_read"] = read_files
    verdicts: list[tuple[str, bool, str]] = []
    if "skill_read" in checks:
        did = "SKILL.md" in read_files
        verdicts.append(("skill_read", did == checks["skill_read"], f"读了 SKILL.md：{did}"))
    if checks.get("must_read_any"):
        hit = [f for f in checks["must_read_any"] if f in read_files]
        verdicts.append(("must_read_any", bool(hit), f"读到：{hit or '无'}"))
    if checks.get("must_mention_any"):
        hit = [w for w in checks["must_mention_any"] if w in result["answer"]]
        verdicts.append(("must_mention_any", bool(hit), f"提到：{hit or '无'}"))
    if checks.get("no_install"):
        bad = [
            _blob(a)
            for n, a in calls
            if n == "mclaw"
            and any(
                k in str(a.get("args", ""))
                for k in ("plugin dev", "packages upload", "packages approve")
            )
        ]
        verdicts.append(("no_install", not bad, f"安装调用：{bad or '无'}"))
    if checks.get("no_scaffold"):
        bad = [
            _blob(a)[:120]
            for n, a in calls
            if ("new_plugin.py" in _blob(a))
            or (n == "write" and "/plugins/" in str(a.get("path", "")))
        ]
        verdicts.append(("no_scaffold", not bad, f"写插件：{bad or '无'}"))
    if result["timed_out"]:
        verdicts.append(("finished", False, "超时仍在运行"))
    return verdicts


def main() -> int:
    parser = argparse.ArgumentParser(description="对真实服务器跑 Agent 技能评测")
    parser.add_argument("skill_dir", type=Path)
    parser.add_argument("--server", required=True)
    parser.add_argument("--ids", help="只跑这些 id，逗号分隔")
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--model", help="指定模型；缺省用服务器的默认模型")
    parser.add_argument("--timeout", type=float, default=900, help="单条最长等待秒数")
    parser.add_argument("--json", type=Path, help="把结果写成 JSON")
    args = parser.parse_args()

    spec = json.loads((args.skill_dir / "evals" / "evals.json").read_text("utf-8"))
    cases = spec["evals"]
    if args.ids:
        wanted = {int(i) for i in args.ids.split(",")}
        cases = [c for c in cases if c["id"] in wanted]
    api = Api(args.server)
    api.login(os.environ["MOVIECLAW_EVAL_USER"], os.environ["MOVIECLAW_EVAL_PASS"])
    try:
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            results = list(
                pool.map(
                    lambda c: run_one(api, c, str(args.skill_dir), args.model, args.timeout), cases
                )
            )
    finally:
        api.logout()

    passed = 0
    scaffolds: set[str] = set()
    for result in results:
        verdicts = judge(result)
        ok = all(v[1] for v in verdicts)
        passed += ok
        case = result["case"]
        print(f"\n{'✅' if ok else '❌'} #{case['id']} {case['prompt']}  （{result['model']}）")
        for name, good, detail in verdicts:
            print(f"   {'✓' if good else '✗'} {name}：{detail}")
        print(f"   读过的技能文件：{result['skill_files_read'] or '无'}")
        expectations = "；".join(case.get("expectations", []))
        print(f"   工具调用 {len(result['calls'])} 次；期望：{expectations}")
        print("   回答：" + result["answer"][-1200:].replace("\n", "\n         "))
        for name, call_args in result["calls"]:
            path = str(call_args.get("path", ""))
            if name == "write" and "/plugins/" in path:
                root, rest = path.split("/plugins/", 1)
                scaffolds.add(f"{root}/plugins/{rest.split('/')[0]}")
    print(f"\n通过 {passed}/{len(results)}")
    if scaffolds:
        print("评测中写下的插件目录（需手动清理）：", "、".join(sorted(scaffolds)))
    if args.json:
        args.json.write_text(json.dumps(results, ensure_ascii=False, indent=2), "utf-8")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
