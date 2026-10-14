#!/usr/bin/env python3
"""Agent 键盘压力测试的隔离 API 服务。

从仓库根目录用 .venv/bin/python apps/apple/scripts/agent-keyboard-lab.py 启动，
再运行 TEST_RUNNER_MC_TEST_KEYBOARD=1 apps/apple/scripts/test.sh
-only-testing:MovieClawUITests/AgentKeyboardUITests。
创建 120 轮会话和一条 127KB Markdown 回复；数据与日志写入新的临时目录。
只注册测试模型以启用输入框，测试不发送消息、不调用模型。Ctrl-C 结束服务。
"""

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx

from movieclaw_api.services.agent_sessions import AgentSessionStore
from movieclaw_llm import ChatMessage

PORT = 18841
PASSWORD = "keyboard-test-2026"


def seed(root: Path) -> None:
    store = AgentSessionStore(root / "data/sessions")
    store.create("scroll-fixture")
    for index in range(120):
        store.append(
            "scroll-fixture",
            ChatMessage(role="user", content=f"滚动验收第 {index + 1} 轮，请整理电影推荐"),
        )
        paragraph = "这是一段用于验证长会话排版的电影介绍，包含剧情、人物与推荐理由。" * (
            1 + index % 13
        )
        parts = [
            f"## 推荐 {index + 1}",
            paragraph,
            "| 电影 | 推荐理由 |\n| --- | --- |\n| 月夜 | 轻松温暖 |\n| 山间 | 风景优美 |",
            "```python\nfor movie in library:\n    print(movie.title)\n```",
        ]
        if index % 3 == 0:
            parts += [paragraph] * 8
        if index == 119:
            parts.append("最新消息定位验收：无需滑动即可看到这一句。")
        store.append(
            "scroll-fixture",
            ChatMessage(role="assistant", content="\n\n".join(parts)),
            finish_reason="stop",
        )

    store.create("keyboard-fixture")
    store.append(
        "keyboard-fixture", ChatMessage(role="user", content="请整理一份完整的电影推荐报告")
    )
    sections = []
    for index in range(160):
        sections.append(
            f"## 章节 {index + 1}\n\n"
            + "电影的**人物、剧情与摄影**值得细看，包含 `inline code` 和[链接](https://example.com)。"
            * (2 + index % 7)
            + "\n\n| 电影 | 推荐理由 |\n| --- | --- |\n| 月夜 | 温暖而平静 |\n| 山间 | 风景优美 |"
            + "\n\n```python\nfor movie in library:\n    print(movie.title)\n```\n\n"
            + "> 一段引用，验证不同高度的 Markdown 块。\n\n- 剧情\n- 人物\n- 摄影"
        )
    text = "\n\n".join(sections) + "\n\n键盘循环验收：最后一段 Markdown。"
    store.append(
        "keyboard-fixture", ChatMessage(role="assistant", content=text), finish_reason="stop"
    )
    print(f"Markdown fixture: {len(text.encode())} bytes, {len(sections)} sections", flush=True)


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="movieclaw-keyboard-"))
    (root / "data").mkdir()
    seed(root)
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root}/data/test.db",
        "SECRET_KEY_FILE": str(root / "data/key"),
        "SCHEDULER_ENABLED": "0",
        "AGENT_SESSIONS_DIR": str(root / "data/sessions"),
        "AGENT_WORKSPACE_DIR": str(root / "data/workspace"),
        "AGENT_SKILLS_DIR": str(root / "data/skills"),
    }
    api_url = f"http://127.0.0.1:{PORT}/api/v1"
    with (root / "api.log").open("w") as log:
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "movieclaw_api.main:app",
                "--factory",
                "--host",
                "127.0.0.1",
                "--port",
                str(PORT),
            ],
            cwd=root,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    try:
        with httpx.Client(timeout=30, trust_env=False) as client:
            for _ in range(120):
                if process.poll() is not None:
                    raise RuntimeError(f"验收服务退出，日志见 {root}")
                try:
                    if client.get(api_url + "/health").status_code == 200:
                        break
                except httpx.RequestError:
                    pass
                time.sleep(0.5)
            else:
                raise RuntimeError(f"验收服务未就绪，日志见 {root}")
            client.post(
                api_url + "/auth/bootstrap", json={"username": "admin", "password": PASSWORD}
            ).raise_for_status()
            client.post(
                api_url + "/llm/providers",
                json={
                    "name": "键盘排版验收",
                    "provider_type": "openai_compat",
                    "base_url": "http://127.0.0.1:1/v1",
                    "api_key": "sk-local-fixture",
                    "default_model": "keyboard-fixture",
                    "extra_models": [
                        {
                            "id": "keyboard-fixture",
                            "context_window": 100000,
                            "max_output_tokens": 8000,
                        }
                    ],
                },
            ).raise_for_status()
        print(f"READY http://127.0.0.1:{PORT}\n日志与临时数据：{root}", flush=True)
        process.wait()
    except KeyboardInterrupt:
        pass
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
