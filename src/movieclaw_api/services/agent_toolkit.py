"""Agent 的工具集与系统提示词装配：网页、IM 通道、插件驱动的会话共用这一处。

工具按档位装配；系统提示词从**本次实际挂上的工具**推导——带 bash/read 才写源码、
日志与技能清单，带 mclaw 才写 <mclaw_service> 服务目录。任何入口拿到的提示词与
工具集合都一一对应，不会出现「提示词让用一个没有的工具」，也不会各入口各拼一份。
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path
from typing import Literal

from movieclaw_agent import AgentTool, build_skills_fragment, build_system_prompt, discover_skills
from movieclaw_agent.tools import builtin_tools, make_mclaw_tool, make_media_ui_tool
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import auth as auth_service
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.mclaw_tool import render_service_block
from movieclaw_api.services.web_search_config import (
    attach_web_search_tool,
    load_web_search_provider,
)
from movieclaw_api.settings import AppServerSetting, get_setting_store
from movieclaw_db.engine import get_database
from movieclaw_db.models.member import Member

#: 工具档位：web = 网页会话与 IM 通道（bash / 文件 / mclaw，网页另加卡片绘制）；
#: full = 同 web 但不带卡片；mclaw = 只有服务操作；none = 不带工具。
#: mclaw / none 只给插件驱动的会话用（docs/design/plugin-agent.md 的授权档位）。
ToolProfile = Literal["web", "full", "mclaw", "none"]


async def agent_cli_env(session_id: str) -> dict[str, str]:
    """构造工作区里 mclaw CLI 的自动授权环境（docs/design/cli.md §6.2）。

    令牌按运行签发、短时效、无状态签名（改密轮换密钥即全体失效）；
    服务器地址走容器内回环直连。Agent 在工作区内执行 `mclaw ...` 即可
    直接操作本产品，全程零登录零交互。
    """
    settings = get_settings()
    token = await auth_service.issue_agent_token(session_id)
    return {
        "MOVIECLAW_SERVER": f"http://127.0.0.1:{settings.port}",
        "MOVIECLAW_TOKEN": token,
    }


def get_agent_tools(cli_env: dict[str, str], *, generative_ui: bool = False) -> list[AgentTool]:
    """Agent 的工具集：内置基础工具 + mclaw 产品操作工具 [+ 卡片绘制工具]。

    bash/read/write/edit 是纯工作区工具，**不携带**产品授权；mclaw 工具
    单独构建，令牌只注入它的子进程（每次运行的令牌不同，因此每次运行都
    重新构建工具集）。

    ``generative_ui`` 是卡片绘制工具（show_media_cards）的开关，**默认关**：
    它的效果完全依赖前端拦截 tool_call 后绘制卡片，只有网页会话有这层界面。
    IM 通道看不到卡片，带上它只会让模型白调一次、用户收到一句「已展示
    卡片」却什么都没有——所以由调用方按所在通道显式打开，新接入的通道不会
    因为忘记关而误带（docs/design/agent-generative-ui.md §2）。
    """
    workdir = Path(get_settings().agent_workspace_dir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    tools = [*builtin_tools(workdir), make_mclaw_tool(workdir, cli_env)]
    if generative_ui:
        tools.append(make_media_ui_tool())
    return tools


async def profile_tools(
    profile: ToolProfile, session_id: str, owner: str | None
) -> list[AgentTool]:
    """按档位构建工具集。令牌按会话签发，所以要在会话建好之后现建。

    网页搜索配好了才挂上；``none`` 档明确不要工具，连搜索也不给。
    """
    if profile == "none":
        return []
    cli_env = await agent_cli_env(session_id)
    web_search = await load_web_search_provider()
    if profile == "mclaw":
        # 只有服务操作的档位：工作目录按来源隔开（插件各用各的）
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in (owner or "web"))
        workdir = Path(get_settings().agent_workspace_dir).resolve() / safe
        workdir.mkdir(parents=True, exist_ok=True)
        return attach_web_search_tool([make_mclaw_tool(workdir, cli_env)], web_search)
    if profile == "web":
        return attach_web_search_tool(get_agent_tools(cli_env, generative_ui=True), web_search)
    # full：没有网页界面的会话，卡片画不出来（docs/design/agent-generative-ui.md §2）
    return attach_web_search_tool(get_agent_tools(cli_env), web_search)


def speaker_member_id(identity: Principal) -> int | None:
    """这一轮是谁在说话（0=超管）。只有真人登录的超管 / 成员才有；Agent、MCP 等程序主体为 None。"""
    if identity.kind == "admin":
        return 0
    if identity.kind == "member":
        return identity.member_id
    return None


async def _nickname(member_id: int) -> str:
    """成员 id → 昵称（0=超管）；没设昵称回退用户名，与网页右上角显示一致。"""
    if member_id == 0:
        admin = await auth_service.get_admin_account()
        return admin.nickname or admin.username
    async with get_database().session() as session:
        member = await session.get(Member, member_id)
    return (member.nickname or member.username) if member is not None else ""


async def agent_system_prompt(
    tools: Sequence[AgentTool], *, speaker: int | None = None
) -> str:
    """组装本次运行的系统提示词：通用正文 + 部署环境事实 + 技能清单 + 服务目录。

    各段按挂上的工具取舍（bash/read/write/edit 同进同出，以 read 为准）：

    - 源码位置、日志目录、技能清单都要靠 bash/read 使用，没有就不写。mclaw 对
      Agent 隐藏了 logs 域（见 services/mclaw_tool 的 _EXCLUDED_DOMAINS），排查
      问题靠这里给出的路径用 bash 直接检索；技能清单的指令要靠 read 加载正文
      （docs/design/agent-skills.md）。
    - 外部访问地址来自「设置 → 应用设置」（保存即生效），每次运行时现读设置
      存储，不做缓存；未配置时不输出。
    - 带 mclaw 时末尾接 <mclaw_service> 服务目录。
    - ``speaker`` 是这一轮说话人的成员 id（0=超管，见 ``speaker_member_id``），
      给了就写上他的昵称；插件驱动等没有真人在说话的会话不给。

    技能清单每次运行现扫：改技能无需重启，下一轮生效。
    """
    names = {tool.name for tool in tools}
    workspace = "read" in names
    lines = []
    if speaker is not None and (nickname := await _nickname(speaker)):
        lines.append(f"- 当前用户的昵称：{nickname}")
    if workspace:
        log_dir = Path(get_settings().log_dir).resolve()
        lines.append(
            f"- 运行日志目录：{log_dir}，按天一个文件（movieclaw-YYYY-MM-DD.log）。"
            "排查问题时用 bash 的 grep/tail 直接检索日志。"
        )
    external_url = (await get_setting_store().get(AppServerSetting)).external_url
    if external_url:
        lines.append(f"- 本应用的外部访问地址：{external_url}。")
    sections = [build_system_prompt("\n".join(lines) or None, workspace=workspace)]
    if workspace:
        user_skills_dir = Path(get_settings().agent_skills_dir).resolve()
        fragment = build_skills_fragment(discover_skills(user_skills_dir), user_skills_dir)
        if fragment is not None:
            sections.append(fragment)
    if "mclaw" in names:
        sections.append(render_service_block())
    return "\n\n".join(sections)
