#!/usr/bin/env python3
"""小幕验收：真实 API / Agent / 工具 / SSE，只有模型替换为确定性的本地服务。

从仓库根目录用 .venv/bin/python apps/apple/scripts/agent-companion-lab.py 启动。
数据库、轨迹与工具工作目录都在新建临时目录；不连接真实模型、不读取用户片库。
默认 API 端口 18831，模型端口 18832；Ctrl-C 结束两个子进程。
加 --scroll-fixture 创建 120 轮长会话，供 MC_TEST_SCROLL=1 的滚动端到端测试使用。
消息带 [pet-error] 触发模型错误，带 [pet-stop] 保持执行以验收停止。
"""

import argparse
import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx


def model_app():
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse, StreamingResponse

    app = FastAPI()

    @app.get("/v1/models")
    async def models():
        return {"object": "list", "data": [{"id": "moon-fixture", "object": "model"}]}

    @app.post("/v1/chat/completions")
    async def completions(request: Request):
        body = await request.json()
        messages = body.get("messages", [])
        last_user = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=0)
        question = (
            json.dumps(messages[last_user].get("content", ""), ensure_ascii=False)
            if messages
            else ""
        )
        base = {"id": "moon", "created": 0, "model": "moon-fixture"}
        if not body.get("stream"):
            return {
                **base,
                "object": "chat.completion",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "月夜电影推荐"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            }
        if "[pet-error]" in question:
            await asyncio.sleep(3)
            return JSONResponse(
                {"error": {"message": "小幕验收：模型暂时不可用", "type": "invalid_request_error"}},
                status_code=400,
            )

        async def stream():
            def chunk(delta, reason=None):
                return (
                    "data: "
                    + json.dumps(
                        {
                            **base,
                            "object": "chat.completion.chunk",
                            "choices": [{"index": 0, "delta": delta, "finish_reason": reason}],
                        },
                        ensure_ascii=False,
                    )
                    + "\n\n"
                )

            yield chunk({"role": "assistant", "reasoning_content": "正在查看测试片库。"})
            await asyncio.sleep(30 if "[pet-stop]" in question else 4)
            if any(m.get("role") == "tool" for m in messages[last_user + 1 :]):
                for text in ["今晚可以看看", "《月夜放映室》", "，这是一部验收用的虚构电影。"]:
                    yield chunk({"content": text})
                    await asyncio.sleep(0.5)
                yield chunk({}, "stop")
            else:
                yield chunk(
                    {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": "moon-library",
                                "type": "function",
                                "function": {
                                    "name": "bash",
                                    "arguments": json.dumps(
                                        {
                                            "command": (
                                                "printf 'Moonlight fixture library: 3 films\\n'"
                                            )
                                        }
                                    ),
                                },
                            }
                        ]
                    }
                )
                yield chunk({}, "tool_calls")
            yield "data: [DONE]\n\n"

        return StreamingResponse(stream(), media_type="text/event-stream")

    return app


def seed_scroll_fixture(root):
    """只写隔离目录：长短段落、表格和代码混排，触发懒加载高度估算变化。"""
    from movieclaw_api.services.agent_sessions import AgentSessionStore
    from movieclaw_llm import ChatMessage

    store = AgentSessionStore(root / "data/sessions")
    store.create("outside-tap-fixture")
    store.append("outside-tap-fixture", ChatMessage(role="user", content="检查点击正文收起键盘"))
    store.append(
        "outside-tap-fixture",
        ChatMessage(
            role="assistant", content="框外轻点验收：点击这段正文应收起键盘，草稿仍然保留。"
        ),
        finish_reason="stop",
    )
    store.create("pet-backdrop-fixture")
    store.append("pet-backdrop-fixture", ChatMessage(role="user", content="检查宠物后方的消息底色"))
    store.append(
        "pet-backdrop-fixture",
        ChatMessage(
            role="assistant",
            content="\n\n".join(
                ["这是一段用于检查宠物周围透明区域的长消息。" * 12] * 20
                + ["最新消息定位验收：无需滑动即可看到这一句。"]
            ),
        ),
        finish_reason="stop",
    )
    for session_id in ("scroll-fixture", "scroll-stream-fixture", "scroll-stopped-fixture"):
        store.create(session_id)
        for index in range(120):
            store.append(
                session_id,
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
                if session_id == "scroll-stopped-fixture":
                    parts += [paragraph] * 8
                parts += ["最新消息定位验收：无需滑动即可看到这一句。"]
            reason = (
                "aborted" if session_id == "scroll-stopped-fixture" and index == 119 else "stop"
            )
            store.append(
                session_id,
                ChatMessage(role="assistant", content="\n\n".join(parts)),
                finish_reason=reason,
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18831)
    parser.add_argument("--model", action="store_true")
    parser.add_argument("--scroll-fixture", action="store_true")
    parser.add_argument(
        "--keyboard-fixture", action="store_true", help="额外创建 100KB 以上的单条 Markdown 回复"
    )
    args = parser.parse_args()
    if args.model:
        import uvicorn

        uvicorn.run(model_app(), host="127.0.0.1", port=args.port, log_level="warning")
        return

    root = Path(tempfile.mkdtemp(prefix="movieclaw-moon-"))
    (root / "data").mkdir()
    if args.scroll_fixture:
        seed_scroll_fixture(root)
    if args.keyboard_fixture:
        from movieclaw_api.services.agent_sessions import AgentSessionStore
        from movieclaw_llm import ChatMessage

        store = AgentSessionStore(root / "data/sessions")
        store.create("keyboard-fixture")
        store.append(
            "keyboard-fixture", ChatMessage(role="user", content="请整理一份完整的电影推荐报告")
        )
        sections = []
        for index in range(160):
            sections.append(
                f"## 章节 {index + 1}\n\n"
                + (
                    "电影的**人物、剧情与摄影**值得细看，包含 "
                    "`inline code` 和[链接](https://example.com)。"
                )
                * (2 + index % 7)
                + "\n\n| 电影 | 推荐理由 |\n| --- | --- |"
                + "\n| 月夜 | 温暖而平静 |\n| 山间 | 风景优美 |"
                + "\n\n```python\nfor movie in library:\n    print(movie.title)\n```\n\n"
                + "> 一段引用，验证不同高度的 Markdown 块。\n\n- 剧情\n- 人物\n- 摄影"
            )
        text = "\n\n".join(sections) + "\n\n键盘循环验收：最后一段 Markdown。"
        store.append(
            "keyboard-fixture", ChatMessage(role="assistant", content=text), finish_reason="stop"
        )
        print(f"Markdown fixture: {len(text.encode())} bytes, {len(sections)} sections", flush=True)
    env = {
        **os.environ,
        "DATABASE_URL": f"sqlite+aiosqlite:///{root}/data/test.db",
        "SECRET_KEY_FILE": str(root / "data/key"),
        "SCHEDULER_ENABLED": "0",
        "AGENT_SESSIONS_DIR": str(root / "data/sessions"),
        "AGENT_WORKSPACE_DIR": str(root / "data/workspace"),
        "AGENT_SKILLS_DIR": str(root / "data/skills"),
    }
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        env.pop(key, None)
    processes = []
    api_url = f"http://127.0.0.1:{args.port}/api/v1"
    try:
        for command, log in [
            (
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--model",
                    "--port",
                    str(args.port + 1),
                ],
                "model.log",
            ),
            (
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "movieclaw_api.main:app",
                    "--factory",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(args.port),
                ],
                "api.log",
            ),
        ]:
            with (root / log).open("w") as output:
                processes.append(
                    subprocess.Popen(
                        command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT
                    )
                )
        with httpx.Client(timeout=30, trust_env=False) as client:
            for _ in range(120):
                if any(process.poll() is not None for process in processes):
                    raise RuntimeError(f"验收进程退出，日志见 {root}")
                try:
                    if client.get(api_url + "/health").status_code == 200:
                        break
                except httpx.RequestError:
                    pass
                time.sleep(0.5)
            else:
                raise RuntimeError(f"验收服务未就绪，日志见 {root}")
            response = client.post(
                api_url + "/auth/bootstrap",
                json={"username": "admin", "password": "moon-test-2026"},
            )
            response.raise_for_status()
            response = client.post(
                api_url + "/llm/providers",
                json={
                    "name": "小幕本地验收",
                    "provider_type": "openai_compat",
                    "base_url": f"http://127.0.0.1:{args.port + 1}/v1",
                    "api_key": "sk-local-fixture",
                    "default_model": "moon-fixture",
                    "extra_models": [
                        {"id": "moon-fixture", "context_window": 100000, "max_output_tokens": 8000}
                    ],
                },
            )
            response.raise_for_status()
        print(
            f"READY http://127.0.0.1:{args.port}  admin / moon-test-2026\n日志与临时数据：{root}",
            flush=True,
        )
        while all(process.poll() is None for process in processes):
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
