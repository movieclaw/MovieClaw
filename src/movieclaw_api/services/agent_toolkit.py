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
from movieclaw_api.services.mclaw_tool import render_service_block
from movieclaw_api.services.web_search_config import (
    attach_web_search_tool,
    load_web_search_provider,
)
from movieclaw_api.settings import AppServerSetting, get_setting_store

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


# 前端页面路由表：模型拼可点击链接的唯一依据（(路径模式, 一行说明)）。
# 与 apps/web/app/(app) 的真实页面结构由守护测试保持同步（见
# tests/api/test_agent.py 的 test_page_routes_match_web_app_pages）——
# 前端加页面、改路径时测试会拦下，这张表不会悄悄过期。
PAGE_ROUTES: list[tuple[str, str]] = [
    ("/", "首页"),
    ("/search", "站点资源搜索页"),
    ("/discover/{movie|tv}", "发现页（电影/剧集的榜单与分类浏览）"),
    (
        "/discover/{movie|tv}/collections/{tmdb|douban}/{片单ID}",
        "完整影视片单（片单引用来自 discover list-collections）",
    ),
    ("/discover/movie/top250", "豆瓣电影 Top250 榜单"),
    ("/discover/movie/high-score", "豆瓣高分电影榜单"),
    ("/discover/people/{TMDB 影人ID}", "发现页影人详情与完整作品列表"),
    ("/media/{movie|tv}/{TMDB ID}", "影片/剧集详情页"),
    ("/media/douban/{豆瓣ID}", "豆瓣词条详情页"),
    ("/subscriptions", "订阅列表"),
    ("/subscriptions/wall/{类型}", "订阅海报墙：tv 全部剧集订阅、movie 全部电影订阅"),
    ("/subscriptions/{订阅ID}", "订阅详情（ID 来自 subscriptions list/get）"),
    ("/library", "媒体库总览（浏览入口：接下来继续、我的收藏、各库最近添加；行可自定义）"),
    ("/library/favorites", "我的收藏（当前账号收藏的全部作品，与 Jellyfin 客户端里点的心同一份）"),
    ("/library/customize", "自定义媒体库首页（行的顺序、显隐、排序与名字；每个成员各存一份）"),
    (
        "/library/kind/{movie|tv|video}",
        "按类型的跨库墙：全部电影 / 全部剧集 / 全部其他视频"
        "（同类型的库合成一面墙，同一部片只出现一次）",
    ),
    ("/library/manage", "媒体库管理（建库、扫描、整理、排序、可见范围；仅管理员）"),
    ("/library/collections", "全部合集总览（含跨库合集；合集 ID 来自 collection list）"),
    (
        "/library/c/{合集ID}",
        "合集详情（不限某个库；库内合集也可从这里打开）",
    ),
    ("/library/{库ID}", "某个媒体库的内容（库 ID 来自 library list）"),
    (
        "/library/{库ID}/c/{合集ID}",
        "库内合集详情：收录规则与成员作品（合集 ID 来自 collection list）",
    ),
    (
        "/library/{库ID}/item/{条目ID}",
        "库内条目详情（条目 ID 来自 library items list）",
    ),
    ("/activity", "活动页（观看：实时播放/下载；任务：后台作业与下载任务）"),
    ("/new", "AI 新任务直达页（Netflix 顶栏「＋ 新任务」入口；与首页共用内容）"),
    ("/sessions/{会话ID}", "AI 会话详情（ID 来自 session list/start）"),
    ("/people/{影人ID}", "影人档案（ID 来自 people 域）"),
    ("/my", "「我的」页（用户信息、快捷入口、AI 会话与账号操作；Netflix 移动端底栏页签）"),
    ("/settings", "设置页"),
]


async def agent_system_prompt(tools: Sequence[AgentTool]) -> str:
    """组装本次运行的系统提示词：通用正文 + 部署环境事实 + 技能清单 + 服务目录。

    各段按挂上的工具取舍（bash/read/write/edit 同进同出，以 read 为准）：

    - 源码位置、日志目录、技能清单都要靠 bash/read 使用，没有就不写。mclaw 对
      Agent 隐藏了 logs 域（见 services/mclaw_tool 的 _EXCLUDED_DOMAINS），排查
      问题靠这里给出的路径用 bash 直接检索；技能清单的指令要靠 read 加载正文
      （docs/design/agent-skills.md）。
    - 外部访问地址来自「设置 → 应用设置」（保存即生效），每次运行时现读设置
      存储，不做缓存；未配置时整块不输出——没有前缀，路由表也拼不出有效链接，
      避免模型给用户无效地址。
    - 带 mclaw 时末尾接 <mclaw_service> 服务目录。

    技能清单每次运行现扫：改技能无需重启，下一轮生效。
    """
    names = {tool.name for tool in tools}
    workspace = "read" in names
    lines = []
    if workspace:
        log_dir = Path(get_settings().log_dir).resolve()
        lines.append(
            f"- 运行日志目录：{log_dir}，按天一个文件（movieclaw-YYYY-MM-DD.log）。"
            "排查问题时用 bash 的 grep/tail 直接检索日志。"
        )
    external_url = (await get_setting_store().get(AppServerSetting)).external_url
    if external_url:
        routes = "\n".join(f"  {pattern}  {desc}" for pattern, desc in PAGE_ROUTES)
        lines.append(
            f"- 本应用的外部访问地址：{external_url}。提到订阅、影片、库内条目等页面时，"
            "尽量附上可点击的 Markdown 链接：以外部访问地址为前缀，路径按下表拼接。"
            f"只拼表内路径，不要用容器内地址拼链接。\n{routes}"
        )
    sections = [build_system_prompt("\n".join(lines) or None, workspace=workspace)]
    if workspace:
        user_skills_dir = Path(get_settings().agent_skills_dir).resolve()
        fragment = build_skills_fragment(discover_skills(user_skills_dir), user_skills_dir)
        if fragment is not None:
            sections.append(fragment)
    if "mclaw" in names:
        sections.append(render_service_block())
    return "\n\n".join(sections)
