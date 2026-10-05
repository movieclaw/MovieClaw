"""mclaw 工具的行为测试（docs/design/agent-cli-integration.md §5）。

覆盖：硬闸（session 递归 / login / server 覆盖）、参数解析错误、真实子进程执行（--help
无需服务器）、退出码语义标注、令牌隔离（bash 拿不到、mclaw 工具拿到）。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from movieclaw_agent.tools.bash import make_bash_tool
from movieclaw_agent.tools.mclaw import build_description, make_mclaw_tool


def _tool(tmp_path: Path, env: dict[str, str] | None = None):
    return make_mclaw_tool(tmp_path, env or {}, "可用服务：\n- subscriptions 订阅")


def test_recursive_session_actions_are_hard_blocked(tmp_path: Path) -> None:
    tool = _tool(tmp_path)
    for args in (
        "session start 帮我整理",
        "session start 继续 --session-id s1",
        "session retry s1 --message-id m2",
        "session follow s1",
        "--output json session start 帮我整理",
    ):
        with pytest.raises(ValueError, match="禁止递归|禁止.*跟随"):
            asyncio.run(tool.handler({"args": args}))


def test_server_override_is_blocked(tmp_path: Path) -> None:
    tool = _tool(tmp_path)
    with pytest.raises(ValueError, match="不允许覆盖服务器地址"):
        asyncio.run(tool.handler({"args": "subscriptions list --server=http://evil"}))


def test_login_logout_blocked(tmp_path: Path) -> None:
    tool = _tool(tmp_path)
    for cmd in ("login --server http://x", "logout", "--output json login"):
        with pytest.raises(ValueError, match="不允许执行 login/logout"):
            asyncio.run(tool.handler({"args": cmd}))


def test_unparseable_args_gives_chinese_error(tmp_path: Path) -> None:
    tool = _tool(tmp_path)
    with pytest.raises(ValueError, match="引号不配对"):
        asyncio.run(tool.handler({"args": 'search torrents "沙丘'}))
    with pytest.raises(ValueError, match="不能为空"):
        asyncio.run(tool.handler({"args": "  "}))


def test_help_runs_without_server(tmp_path: Path) -> None:
    """--help 走内置基线 spec，断网/无服务器也能探索命令面。"""
    tool = _tool(tmp_path)
    result = asyncio.run(tool.handler({"args": "subscriptions --help"}))
    assert "create" in result and "list" in result
    assert "[退出码" not in result  # 成功不标注


def test_get_transcript_stdout_is_never_truncated(tmp_path: Path, monkeypatch) -> None:
    """完整轨迹由模型自行取舍，工具层不得套用通用的输出截断。"""
    payload = "轨迹" * 30000

    class _Process:
        returncode = 0

        async def communicate(self):
            return payload.encode(), b""

    async def create_process(*_args, **_kwargs):
        return _Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", create_process)
    result = asyncio.run(_tool(tmp_path).handler({"args": "session get-transcript s1"}))
    assert result == payload


def test_exit_code_annotation_teaches_next_step(tmp_path: Path) -> None:
    """用法错误（2）的结果里附中文指引：先 --help 再试。"""
    tool = _tool(tmp_path)
    result = asyncio.run(tool.handler({"args": "subscriptions get"}))  # 缺必填参数
    assert "[退出码 2" in result and "--help" in result


def test_network_failure_annotated_as_exit_4(tmp_path: Path) -> None:
    tool = _tool(
        tmp_path,
        {"MOVIECLAW_SERVER": "http://127.0.0.1:9", "MOVIECLAW_CONFIG_DIR": str(tmp_path)},
    )
    result = asyncio.run(tool.handler({"args": "subscriptions list --timeout 3"}))
    assert "[退出码 4" in result and "无法连接" in result


def test_token_only_reaches_mclaw_tool_not_bash(tmp_path: Path) -> None:
    """令牌隔离：mclaw 工具子进程拿得到注入环境，bash 工具拿不到。"""
    bash = make_bash_tool(tmp_path)  # 装配层不再向 bash 注入 cli env
    result = asyncio.run(bash.handler({"command": "echo token=[$MOVIECLAW_TOKEN]"}))
    assert "token=[]" in result

    mclaw = _tool(tmp_path, {"MOVIECLAW_TOKEN": "tok-1", "MOVIECLAW_SERVER": "http://127.0.0.1:9"})
    # 工具子进程确实带上了环境：借 --debug 的脱敏通道无从验证，这里用
    # 网络失败路径证明 SERVER 环境生效（地址来自注入值）
    result = asyncio.run(mclaw.handler({"args": "subscriptions list --timeout 3"}))
    assert "127.0.0.1:9" in result


def test_description_contains_service_map_and_protocol() -> None:
    desc = build_description("可用服务：\n- subscriptions 订阅")
    assert "可用服务" in desc and "subscriptions 订阅" in desc
    assert "--help" in desc and "--yes" in desc
    assert "bash" in desc  # 排他性引导：不要经 bash 调用
    assert "discover 浏览榜单" in desc
    assert "search titles 找片/找剧" in desc
    assert "search library 查已有库存" in desc
    assert "session 只用于管理" not in desc


def test_args_description_contains_representative_discovery_example(tmp_path: Path) -> None:
    """参数提示同时示范发现内容与资源搜索，帮助模型形成正确的命令形态。"""
    tool = _tool(tmp_path)
    args_desc = tool.definition.parameters["properties"]["args"]["description"]
    assert "discover list-collections --media-type movie --provider tmdb" in args_desc
    assert "subscriptions list" in args_desc
    assert 'search torrents "沙丘2" --resolution 2160p' in args_desc
