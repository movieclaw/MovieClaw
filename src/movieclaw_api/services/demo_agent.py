"""公开演示站的 AI 助手：预置对话 + 预设回复的「演示模型」（docs/design/demo-site.md §7）。

演示站不接真实大模型（没有 Key，也不该让公开访客消耗额度），又想让访客看到
AI 助手长什么样、能做什么。这里做三件事：

1. **演示模型**：``DemoLlmRouter`` 顶替真实的模型路由，Agent 运行时的其余部分
   （转录落盘、SSE 事件流、工具调用、媒体卡片渲染）原样工作。它不理解语言，
   按关键词判断意图（推荐、新入库、字幕、观看统计、订阅、播放……），用媒体库里
   的**真实数据**拼出回复，并像真模型一样逐字流式输出。认不出的问题如实说明
   「这是演示站的预设回复」——模型名也叫「演示模型（预设回复）」，不冒充真 AI；
2. **只读工具**：演示运行只挂两个工具——媒体卡片，和一个名为 ``mclaw`` 的
   只读查库工具（输出由演示模型生成计划时算好，不执行任何命令）。bash、读写
   文件、真正的命令行一概不挂：即便脚本写错点了名，工具校验也会拒绝执行；
3. **预置对话，按设备隔离**：演示站的账号是公开的，所有访客共用同一个超管，
   而会话本来是全局的。于是每台设备（登录设备行）第一次打开会话列表时，得到
   一套属于它自己的预置对话副本（会话编号由「设备 + 用例」推导，重启后仍对得上）；
   访客自己新开的对话只记在进程内存里、只对发起它的设备可见，重启后一律隐藏，
   每日还原时随 data/ 一起清掉。访客打的字因此永远不会出现在别人的列表里。
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import random
import re
import time
import uuid
from collections import OrderedDict, deque
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from movieclaw_agent.toolkit import AgentTool
from movieclaw_agent.tools.media_ui import TOOL_NAME as MEDIA_CARDS_TOOL
from movieclaw_agent.tools.media_ui import make_media_ui_tool
from movieclaw_api.exceptions import AppException
from movieclaw_api.services.agent_sessions import (
    SessionHeader,
    SessionMessageEntry,
    get_agent_session_store,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileState,
    LibraryFile,
    MediaItem,
    PlaybackLog,
    Subscription,
    WantedItem,
)
from movieclaw_db.models.agent_session import AgentSession
from movieclaw_db.models.library import Library
from movieclaw_db.models.member import Member
from movieclaw_llm.models import (
    ChatMessage,
    ChatRequest,
    ChatResponse,
    ChatStreamEvent,
    LlmProviderConfig,
    ModelInfo,
    TokenUsage,
    ToolCall,
    ToolDefinition,
)
from movieclaw_llm.router import LlmRouter

logger = logging.getLogger("movieclaw_api.demo_agent")

DEMO_PROVIDER = "演示模型"
DEMO_MODEL = "demo-preset"
DEMO_MODEL_LABEL = "演示模型（预设回复）"

_CONFIG = LlmProviderConfig(
    name=DEMO_PROVIDER,
    provider_type="demo",
    api_key="",
    default_model=DEMO_MODEL,
    is_default=True,
)

# ---------------------------------------------------------------------------
# 媒体库事实：演示模型的全部「知识」都从这里来
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _Film:
    item_id: int
    title: str
    original: str
    year: int | None
    library: str
    duration_s: int
    resolution: str | None
    video_codec: str | None
    bit_rate: int | None
    subtitles: tuple[str, ...]
    audio: tuple[str, ...]

    @property
    def name(self) -> str:
        """对话里的片名：中文名附原名。「寻龙记」（Sintel）与商业片《寻龙诀》只差一字，
        原名放前面，一眼看出是开放电影。"""
        if not self.original or self.original == self.title:
            return self.title
        if "寻龙" in self.title:
            return f"{self.original}（{self.title}）"
        return f"{self.title}（{self.original}）"

    @property
    def minutes(self) -> str:
        return f"{self.duration_s // 60}:{self.duration_s % 60:02d}"


_LANG = {"chi": "中文", "zho": "中文", "eng": "英语", "jpn": "日语", "ger": "德语", "fre": "法语",
         "spa": "西班牙语", "ita": "意大利语", "rus": "俄语", "por": "葡萄牙语"}  # fmt: skip


def _track_label(track: dict) -> str:
    code = track.get("language") or "und"
    return track.get("title") or _LANG.get(code, "未标语言" if code == "und" else code)


async def _films() -> list[_Film]:
    async with get_database().session() as session:
        rows = await session.execute(
            select(
                MediaItem.id,
                MediaItem.title,
                MediaItem.original_title,
                MediaItem.year,
                Library.name,
                LibraryFile.duration_seconds,
                LibraryFile.resolution,
                LibraryFile.video_codec,
                LibraryFile.bit_rate,
                LibraryFile.external_subtitles,
                LibraryFile.subtitle_streams,
                LibraryFile.audio_streams,
            )
            .join(LibraryFile, LibraryFile.media_item_id == MediaItem.id)
            .join(Library, Library.id == LibraryFile.library_id)
            .where(LibraryFile.state == FileState.IN_PLACE, Library.kind != "photo")
            .order_by(MediaItem.id)
        )
        films: dict[int, _Film] = {}
        for row in rows:
            item_id, title, original, year, library, seconds, res, codec, rate = row[:9]
            external, embedded, audio = row[9] or [], row[10] or [], row[11] or []
            films.setdefault(
                item_id,
                _Film(
                    item_id, title, original, year, library, int(seconds or 0), res, codec, rate,
                    tuple(_track_label(t) for t in [*embedded, *external]),
                    tuple(_track_label(t) for t in audio),
                ),
            )  # fmt: skip
        return list(films.values())


def _mentioned(text: str, films: list[_Film]) -> _Film | None:
    lowered = text.lower()
    for film in films:
        names = [film.title, film.original]
        if any(n and n.lower() in lowered for n in names):
            return film
    return None


# ---------------------------------------------------------------------------
# 回复计划：一轮回复 = 若干步，每步「一段文字 + 可选一次工具调用」
# ---------------------------------------------------------------------------


@dataclass
class _Step:
    text: str
    tool: str | None = None
    arguments: dict = field(default_factory=dict)
    # 只读查库工具的预设输出（演示模型生成计划时就算好了）
    output: str | None = None


def _query(command: str, output: str) -> _Step:
    return _Step(text="", tool="mclaw", arguments={"args": command}, output=output)


def _cards(films: list[_Film], title: str) -> _Step:
    return _Step(
        text="",
        tool=MEDIA_CARDS_TOOL,
        arguments={
            "component": "library_item",
            "items": [{"media_item_id": f.item_id} for f in films],
            "title": title,
        },
    )


def _table(films: list[_Film]) -> str:
    lines = ["media_item_id  片名  年份  媒体库  时长"]
    lines += [f"{f.item_id}  {f.name}  {f.year or '-'}  {f.library}  {f.minutes}" for f in films]
    return "\n".join(lines)


_DEMO_NOTE = (
    "（这里是 MovieClaw 的公开演示站，AI 助手用的是**预设回复**，不连真实大模型。"
    "自己部署并接入模型后，它能听懂任意说法，还能直接帮你订阅、整理媒体库、排查播放问题。）"
)


async def _plan_recommend_kids(films: list[_Film], rng: random.Random) -> list[_Step]:
    shorts = [f for f in films if f.library == "动画短片"] or films
    picks = sorted(rng.sample(shorts, k=min(3, len(shorts))), key=lambda f: f.duration_s)
    total = sum(f.duration_s for f in picks) // 60
    return [
        _Step("我先看看媒体库里有哪些适合全家一起看的动画短片。"),
        _query('library items list --library 动画短片 --sort runtime', _table(shorts)),
        _Step("挑了几部轻松、没有台词门槛的："),
        _cards(picks, "适合和孩子一起看"),
        _Step(
            f"这几部加起来大约 {max(total, 1)} 分钟，一部接一部刚好。"
            + ("Caminandes 系列讲的是一只小羊驼的日常，笑点全靠动作，小朋友最容易看懂。"
               if any("Caminandes" in f.original for f in picks) else "")
            + "\n\n想让孩子自己看的话，可以用「小朋友」账号登录：它只看得到「动画短片」和「图片」，"
            "内容分级也限在 7 岁以下。"
        ),
    ]  # fmt: skip


async def _plan_new_arrivals(films: list[_Film], rng: random.Random) -> list[_Step]:
    async with get_database().session() as session:
        rows = await session.execute(
            select(WantedItem.media_item_id, WantedItem.imported_at)
            .where(WantedItem.imported_at.is_not(None))
            .order_by(WantedItem.imported_at.desc())
            .limit(3)
        )
        recent = [(item_id, at) for item_id, at in rows]
    by_id = {f.item_id: f for f in films}
    picks = [by_id[i] for i, _ in recent if i in by_id] or films[-3:]
    return [
        _Step("查一下最近入库的记录。"),
        _query("library items list --sort added --limit 3", _table(picks)),
        _Step(f"最近一周新入库了 {len(picks)} 部："),
        _cards(picks, "本周新入库"),
        _Step(
            "它们都是跟着订阅自动收进来的：下载完成后按命名规则整理、刮削海报和简介，"
            "然后直接出现在海报墙上。订阅页的「刚刚入库」一栏也能看到。"
        ),
    ]


async def _plan_subtitles(film: _Film) -> list[_Step]:
    subs = "、".join(film.subtitles) or "暂无"
    audio = "、".join(film.audio) or "未知"
    has_chinese = any("中文" in s for s in film.subtitles)
    detail = "\n".join(
        [f"片名: {film.name}", f"音轨: {audio}", f"字幕: {subs}", f"视频: {film.resolution} "
         f"{(film.video_codec or '').upper()}"]
    )  # fmt: skip
    return [
        _Step(f"我查一下《{film.name}》的文件信息。"),
        _query(f"library items get {film.item_id} --tracks", detail),
        _Step(""),
        _cards([film], "点这里直接播放"),
        _Step(
            (f"有。《{film.name}》带 {len(film.subtitles)} 条字幕：{subs}。"
             if has_chinese else f"《{film.name}》目前的字幕有：{subs}，没有中文字幕。")
            + "\n\n切换方法：播放时点控制栏上的「字幕」按钮（手机上先点一下画面调出控制栏），"
            "选想要的语言即可。"
            + ("" if has_chinese else "没有中文字幕时，接入模型后可以让我用 AI 生成一份。")
        ),
    ]  # fmt: skip


async def _plan_stats(films: list[_Film]) -> list[_Step]:
    since = datetime.now(UTC).replace(tzinfo=None) - timedelta(days=7)
    async with get_database().session() as session:
        per_member = (
            await session.execute(
                select(
                    PlaybackLog.member_id,
                    func.count(PlaybackLog.id),
                    func.sum(PlaybackLog.watched_ms),
                )
                .where(PlaybackLog.started_at >= since)
                .group_by(PlaybackLog.member_id)
                .order_by(func.sum(PlaybackLog.watched_ms).desc())
            )
        ).all()
        top = (
            await session.execute(
                select(PlaybackLog.media_item_id, func.count(PlaybackLog.id))
                .where(PlaybackLog.started_at >= since)
                .group_by(PlaybackLog.media_item_id)
                .order_by(func.count(PlaybackLog.id).desc())
                .limit(3)
            )
        ).all()
        names = {
            m.id: (m.nickname or m.username)
            for m in (await session.execute(select(Member))).scalars()
        }
    names[0] = "管理员"
    lines = [
        f"{names.get(mid, '成员')}: {plays} 场, {round((ms or 0) / 60000)} 分钟"
        for mid, plays, ms in per_member
    ]
    by_id = {f.item_id: f for f in films}
    top_films = [by_id[i] for i, _ in top if i in by_id]
    if not per_member:
        return [_Step("最近 7 天家里还没有人看过片。活动页的「观看统计」会随播放自动累积。")]
    leader, plays, ms = per_member[0]
    return [
        _Step("我看一下最近 7 天的播放记录。"),
        _query("playback stats watch --days 7", "\n".join(lines)),
        _Step(
            f"最近 7 天看得最多的是**{names.get(leader, '成员')}**：{plays} 场、"
            f"约 {round((ms or 0) / 60000)} 分钟。全家的情况：\n\n"
            + "\n".join(f"- {line}" for line in lines)
            + "\n\n播放次数最多的几部："
        ),
        _cards(top_films, "最近 7 天最常播放") if top_films else _Step(""),
        _Step("更细的分布（按天、按时段、按设备）在「活动 → 观看统计」里，能切 7 / 30 / 90 天。"),
    ]


async def _plan_subscribe(films: list[_Film]) -> list[_Step]:
    async with get_database().session() as session:
        subs = (
            await session.execute(
                select(Subscription.id, MediaItem.title, Subscription.status)
                .join(MediaItem, MediaItem.id == Subscription.media_item_id)
                .order_by(Subscription.updated_at.desc())
                .limit(3)
            )
        ).all()
    listing = "\n".join(f"{sid}  {title}  {status}" for sid, title, status in subs) or "（空）"
    steps = [
        _Step("先看看现在都订阅了什么。"),
        _query("subscriptions list --limit 3", "id  片名  状态\n" + listing),
    ]
    if subs:
        steps.append(
            _Step(
                "",
                tool=MEDIA_CARDS_TOOL,
                arguments={
                    "component": "subscription",
                    "items": [{"subscription_id": sid} for sid, _, _ in subs],
                    "title": "最近的订阅",
                },
            )
        )
    from movieclaw_tracker.sites.custom.demo import load_catalog

    waiting = "、".join(entry["title"] for entry in load_catalog() if entry.get("title"))
    tail = (
        f"这台演示站接的是一个只收开放授权影片的演示资源站：{waiting} 这几部 Blender "
        "开放电影还没入库，订阅其中一部，就能看到从找到资源、下载到入库的整个过程，"
        "几分钟后它会出现在「电影」库里。"
        if waiting
        else "上面这些订阅都是演示数据。"
    )
    steps.append(
        _Step(
            "可以。订阅就是为这个准备的：在「发现」里找到想看的片，点「订阅」，之后一有"
            "资源就会自动下载、改名、刮削、入库，你什么都不用管；剧集会一直追到新集出齐。\n\n"
            + tail
        )
    )
    return steps


async def _plan_playback(films: list[_Film]) -> list[_Step]:
    sample = max(films, key=lambda f: f.bit_rate or 0) if films else None
    detail = (
        f"片名: {sample.name}\n规格: {sample.resolution} {(sample.video_codec or '').upper()} "
        f"{round((sample.bit_rate or 0) / 1_000_000, 1)} Mbps\n播放方式: 直连（无需转码）"
        if sample
        else "（媒体库为空）"
    )
    return [
        _Step("我拿库里码率最高的一部看看播放时的实际情况。"),
        _query(
            f"playback decide {sample.item_id if sample else 0} --client ios --network cellular",
            detail,
        ),
        _Step(
            "一般不会卡。演示站的片子都是 H.264 + AAC 的 MP4，网页和 iOS App 都能**直连播放**，"
            "服务器不用转码。\n\n"
            "判断规则大致是：\n"
            "- 设备能直接解码的格式 → 直连，画质无损、服务器零负担；\n"
            "- 只是封装不兼容（比如 MKV）→ 只换封装，几乎不耗 CPU；\n"
            "- 码率超过当前网络承受力（比如用流量看 4K）→ 按你选的画质上限转码，"
            "有显卡就用硬件转码。\n\n"
            "用流量看的话，可以在播放器的「设置」里把画质上限设成 720p，省流量也更稳；"
            "这个选择会记住，不用每部片重选。"
        ),
    ]


async def _plan_search(film: _Film) -> list[_Step]:
    return [
        _Step(f"我在媒体库里找一下「{film.original or film.title}」。"),
        _query(f'search library-items "{film.original or film.title}"', _table([film])),
        _Step("找到了："),
        _cards([film], "媒体库里有这部"),
        _Step(f"{film.library}库里就有，{film.minutes} 分钟，点卡片就能直接播放。"),
    ]


async def _plan_intro(films: list[_Film]) -> list[_Step]:
    return [
        _Step(
            "你好！我是 MovieClaw 的 AI 助手。平时我能帮你：\n\n"
            "- 按心情、按人推荐库里的片子，直接给出能播放的卡片；\n"
            "- 订阅想看的电影和剧集，资源一出就自动下载入库；\n"
            "- 查字幕、查音轨、排查播放卡顿；\n"
            "- 看看家里最近谁在看什么。\n\n"
            "可以试试问我：「今晚想和孩子看点轻松的」「这周新添了哪些片」"
            "「钢铁之泪有中文字幕吗」「家里最近谁看得最多」。\n\n" + _DEMO_NOTE
        )
    ]


async def _plan_fallback(films: list[_Film], rng: random.Random) -> list[_Step]:
    picks = rng.sample(films, k=min(3, len(films))) if films else []
    steps = [
        _Step(
            "这个问题超出了演示站预设回复的范围 🙂\n\n" + _DEMO_NOTE + "\n\n"
            "演示站能回答这类问题：推荐片子、这周新入库了什么、某部片有没有中文字幕、"
            "家里最近谁看得最多、订阅怎么用、手机上看会不会卡。先送你几部库里的片子："
        )
    ]
    if picks:
        steps += [_cards(picks, "随便看看"), _Step("点卡片就能直接播放。")]
    return steps


_INTENTS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("subtitles", ("字幕", "subtitle")),
    ("stats", ("谁看", "看得最多", "统计", "看了什么", "看了些什么", "观看记录", "最近在看")),
    ("new", ("新入库", "新添", "新加", "最近入库", "新片", "这周", "本周", "最近添加")),
    ("subscribe", ("订阅", "自动收", "追更", "追剧", "自动下载")),
    ("playback", ("卡", "转码", "4k", "流量", "画质", "码率", "缓冲")),
    ("kids", ("孩子", "小朋友", "儿童", "全家", "轻松", "动画")),
    ("recommend", ("推荐", "看什么", "看点", "好看", "今晚")),
    ("intro", ("你好", "您好", "hello", "hi", "你是谁", "能做什么", "会什么", "怎么用")),
)


async def plan_reply(text: str) -> list[_Step]:
    """按关键词给出这一轮回复的完整计划（同一问题结果确定，便于重放与测试）。"""
    films = await _films()
    rng = random.Random(hashlib.sha1(text.encode()).hexdigest())
    lowered = text.lower()
    intent = next((name for name, words in _INTENTS if any(w in lowered for w in words)), None)
    mentioned = _mentioned(text, films)
    if intent == "subtitles":
        target = mentioned or next((f for f in films if "中文" in "".join(f.subtitles)), None)
        if target is not None:
            return await _plan_subtitles(target)
    if intent == "stats":
        return await _plan_stats(films)
    if intent == "new":
        return await _plan_new_arrivals(films, rng)
    if intent == "subscribe":
        return await _plan_subscribe(films)
    if intent == "playback":
        return await _plan_playback(films)
    if mentioned is not None:
        return await _plan_search(mentioned)
    if intent in ("kids", "recommend") and films:
        return await _plan_recommend_kids(films, rng)
    if intent == "intro":
        return await _plan_intro(films)
    return await _plan_fallback(films, rng)


def _merge(steps: list[_Step]) -> list[_Step]:
    """把「纯文字步」并进紧随其后的工具步：一次模型回复 = 一段文字 + 至多一次工具调用。"""
    merged: list[_Step] = []
    pending = ""
    for step in steps:
        if step.tool is None:
            pending = f"{pending}\n\n{step.text}".strip() if step.text else pending
            continue
        merged.append(_Step(pending, step.tool, step.arguments, step.output))
        pending = ""
    # 收尾必须有正文：运行时把「没有工具调用、正文也空」当成空响应重试直至报错
    merged.append(_Step(pending or "以上就是结果。"))
    return merged


def _tool_call(step: _Step) -> ToolCall:
    raw = json.dumps(step.arguments, ensure_ascii=False)
    return ToolCall(
        id=f"call_{uuid.uuid4().hex[:16]}",
        name=step.tool or "",
        arguments=step.arguments,
        raw_arguments=raw,
    )


# 只读查库工具的输出：演示模型生成计划时写入，工具执行时读出（按参数串索引）
_command_outputs: OrderedDict[str, str] = OrderedDict()


def _remember_output(step: _Step) -> None:
    if step.tool == "mclaw" and step.output is not None:
        _command_outputs[step.arguments["args"]] = step.output
        _command_outputs.move_to_end(step.arguments["args"])
        while len(_command_outputs) > 512:
            _command_outputs.popitem(last=False)


# ---------------------------------------------------------------------------
# 演示模型：Agent 运行时眼里的「供应商」
# ---------------------------------------------------------------------------


def _current_turn(messages: list[ChatMessage]) -> tuple[str, int]:
    """(本轮用户问题, 本轮已经完成的模型回复数)。"""
    last_user = max((i for i, m in enumerate(messages) if m.role == "user"), default=-1)
    text = messages[last_user].text() if last_user >= 0 else ""
    done = sum(1 for m in messages[last_user + 1 :] if m.role == "assistant")
    return text, done


class DemoLlmRouter(LlmRouter):
    """顶替真实模型路由：解析永远落到演示模型，回复按计划流式吐出。"""

    def __init__(self) -> None:
        super().__init__([_CONFIG])

    def resolve(self, model_ref: str) -> tuple[LlmProviderConfig, str]:
        return _CONFIG, DEMO_MODEL

    def get_model_info(self, model_ref: str) -> ModelInfo:
        # 不声明上下文窗口：自动压缩停用（压缩要调用模型做摘要）
        return ModelInfo(id=DEMO_MODEL)

    async def chat(self, request: ChatRequest) -> ChatResponse:
        final = ChatResponse(model=DEMO_MODEL, provider=DEMO_PROVIDER)
        async for event in self.chat_stream(request):
            final = event.partial
        return final

    async def chat_stream(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        question, done = _current_turn(request.messages)
        steps = _merge(await plan_reply(question))
        step = steps[min(done, len(steps) - 1)]
        _remember_output(step)
        partial = ChatResponse(model=DEMO_MODEL, provider=DEMO_PROVIDER)
        yield ChatStreamEvent(type="start", partial=partial.model_copy())
        await asyncio.sleep(0.35)  # 「思考」一下再开口
        text = step.text
        for start in range(0, len(text), 3):
            chunk = text[start : start + 3]
            partial.content = (partial.content or "") + chunk
            yield ChatStreamEvent(type="text_delta", delta=chunk, partial=partial.model_copy())
            await asyncio.sleep(0.02)
        if step.tool:
            call = _tool_call(step)
            yield ChatStreamEvent(
                type="toolcall_start",
                tool_call=call.model_copy(update={"arguments": {}, "raw_arguments": ""}),
                partial=partial.model_copy(),
            )
            yield ChatStreamEvent(
                type="toolcall_delta",
                delta=call.raw_arguments,
                tool_call=call,
                partial=partial.model_copy(),
            )
            partial.tool_calls = [call]
            yield ChatStreamEvent(type="toolcall_end", tool_call=call, partial=partial.model_copy())
        partial.finish_reason = "tool_calls" if step.tool else "stop"
        partial.usage = TokenUsage(
            prompt_tokens=sum(len(m.text()) for m in request.messages) // 2,
            completion_tokens=len(text) // 2 + 8,
        )
        partial.usage.total_tokens = partial.usage.prompt_tokens + partial.usage.completion_tokens
        yield ChatStreamEvent(type="done", partial=partial)


_router: DemoLlmRouter | None = None


def router() -> DemoLlmRouter:
    global _router
    if _router is None:
        _router = DemoLlmRouter()
    return _router


def tools() -> list[AgentTool]:
    """演示运行的全部工具：媒体卡片 + 只读查库。不挂 bash / 文件读写 / 真命令行。"""

    async def query(args: dict) -> str:
        return _command_outputs.get(str(args.get("args", "")), "（演示站：这条查询没有预设结果）")

    return [
        make_media_ui_tool(),
        AgentTool(
            definition=ToolDefinition(
                name="mclaw",
                description="查询 MovieClaw 媒体库（演示站：只读，结果为预设）",
                parameters={
                    "type": "object",
                    "properties": {"args": {"type": "string"}},
                    "required": ["args"],
                },
            ),
            handler=query,
        ),
    ]


SYSTEM_PROMPT = "演示站的预设回复模型（不调用真实大模型）。"

# ---------------------------------------------------------------------------
# 预置对话：每台设备一套自己的副本
# ---------------------------------------------------------------------------

# (用例键, 问题, 几天前)
_CASES: tuple[tuple[str, str, float], ...] = (
    ("kids", "今晚想和孩子一起看点轻松的，有什么推荐？", 0.3),
    ("new", "这周媒体库新添了哪些片？", 1.2),
    ("subtitles", "《钢铁之泪》有中文字幕吗？在播放器里怎么切换？", 2.1),
    ("stats", "家里最近谁看得最多？都看了些什么？", 3.4),
    ("subscribe", "Blender 以后出新片的话，能自动帮我收进来吗？", 4.6),
    ("playback", "在手机上用流量看这些片，会不会卡？要不要转码？", 6.0),
)
_NAMESPACE = uuid.UUID("4c6f7a66-6d6f-7669-6563-6c61772d6465")

# 访客自己新开的会话 → 发起它的设备（只在进程内存里；重启后这些会话一律隐藏）
_owners: dict[str, str] = {}
_seed_lock = asyncio.Lock()


def _device_key(principal) -> str:
    device = getattr(principal, "device", None)
    return f"device:{device.id}" if device is not None else f"anon:{principal.name}"


def _case_session_id(device_key: str, case: str) -> str:
    return uuid.uuid5(_NAMESPACE, f"{device_key}:{case}").hex


def _device_session_ids(device_key: str) -> set[str]:
    return {_case_session_id(device_key, case) for case, _, _ in _CASES}


def is_visible(session_id: str, principal) -> bool:
    """演示站上这个会话对当前设备可见吗：自己那套预置对话，或自己发起的会话。"""
    key = _device_key(principal)
    return session_id in _device_session_ids(key) or _owners.get(session_id) == key


def claim(session_id: str, principal) -> None:
    """记下访客新开的会话属于哪台设备。"""
    _owners[session_id] = _device_key(principal)


# 每台设备的对话配额：演示站谁都能发消息，每条消息都会写转录、占运行历史内存。
# 正常体验远用不到这个量；超了就明说，并引导回已有会话继续聊
MAX_NEW_SESSIONS_PER_DEVICE = 20
MESSAGE_WINDOW_SECONDS = 600
MAX_MESSAGES_PER_WINDOW = 40
_MAX_TRACKED_DEVICES = 20000
_message_times: dict[str, deque[float]] = {}


def ensure_can_send(principal, *, new_session: bool) -> None:
    """发消息 / 重试前调用：超出本设备的会话数或消息频率配额时抛 429。"""
    key = _device_key(principal)
    if new_session and sum(1 for owner in _owners.values() if owner == key) >= (
        MAX_NEW_SESSIONS_PER_DEVICE
    ):
        raise AppException(
            status_code=429,
            code="DEMO_QUOTA_EXCEEDED",
            message=f"演示站每台设备最多新开 {MAX_NEW_SESSIONS_PER_DEVICE} 个会话，"
            "可以在已有的会话里继续聊",
        )
    now = time.monotonic()
    times = _message_times.get(key)
    if times is None:
        if len(_message_times) >= _MAX_TRACKED_DEVICES:
            stale = [k for k, v in _message_times.items() if now - v[-1] > MESSAGE_WINDOW_SECONDS]
            for k in stale or list(_message_times)[: _MAX_TRACKED_DEVICES // 2]:
                del _message_times[k]
        times = _message_times[key] = deque()
    while times and now - times[0] > MESSAGE_WINDOW_SECONDS:
        times.popleft()
    if len(times) >= MAX_MESSAGES_PER_WINDOW:
        raise AppException(
            status_code=429,
            code="DEMO_QUOTA_EXCEEDED",
            message="演示站的 AI 助手发消息太频繁了，请过几分钟再试",
        )
    times.append(now)


async def _transcript(question: str, start: datetime) -> list[SessionMessageEntry]:
    """把一个问题完整跑一遍演示模型的计划，得到可直接落盘的转录（不流式、不等待）。"""
    steps = _merge(await plan_reply(question))
    entries: list[SessionMessageEntry] = []
    at = start

    def add(message: ChatMessage, **extra) -> None:
        nonlocal at
        entries.append(
            SessionMessageEntry(
                uuid=uuid.uuid4().hex[:12],
                parent_uuid=entries[-1].uuid if entries else None,
                timestamp=at.isoformat(),
                message=message,
                **extra,
            )
        )
        at += timedelta(seconds=2)

    add(ChatMessage(role="user", content=question))
    for step in steps:
        call = _tool_call(step) if step.tool else None
        add(
            ChatMessage(role="assistant", content=step.text, tool_calls=[call] if call else None),
            model=DEMO_MODEL,
            finish_reason="tool_calls" if call else "stop",
        )
        if call is not None:
            _remember_output(step)
            output = step.output if step.tool == "mclaw" else "ok"
            add(
                ChatMessage(role="tool", content=output or "", tool_call_id=call.id, name=call.name)
            )
    return entries


async def ensure_device_sessions(principal) -> None:
    """给这台设备补齐一套预置对话（已有的跳过）。演示数据缺席时静默跳过。"""
    key = _device_key(principal)
    store = get_agent_session_store()
    now = datetime.now(UTC)
    # 串行化：同一台新设备同时发两次列表请求时，两边都会发现预置对话缺席、
    # 都去插同一个主键——加锁后第二个请求会看到第一个已经写好的记录直接跳过
    async with _seed_lock, get_database().session() as session:
        for case, question, days in _CASES:
            session_id = _case_session_id(key, case)
            if await session.get(AgentSession, session_id) is not None:
                continue
            start = now - timedelta(days=days)
            try:
                entries = await _transcript(question, start)
            except Exception:  # noqa: BLE001 - 单个用例出错不影响其它用例
                logger.exception("生成预置对话失败 case=%s", case)
                continue
            header = SessionHeader(session_id=session_id, created_at=start.isoformat())
            store.root.mkdir(parents=True, exist_ok=True)
            with store.path(session_id).open("w", encoding="utf-8") as f:
                f.write(header.model_dump_json() + "\n")
                for entry in entries:
                    f.write(entry.model_dump_json(exclude_none=True) + "\n")
            last = datetime.fromisoformat(entries[-1].timestamp).replace(tzinfo=None)
            session.add(
                AgentSession(
                    id=session_id,
                    title=_title(question),
                    last_prompt=question,
                    entry_count=len(entries),
                    leaf_uuid=entries[-1].uuid,
                    created_at=start.replace(tzinfo=None),
                    updated_at=last,
                )
            )
        await session.commit()


def _title(question: str) -> str:
    return re.sub(r"\s+", " ", question).strip()[:40]


def visible_ids(principal) -> list[str]:
    """当前设备看得见的全部会话编号：自己那套预置对话 + 自己发起的会话。"""
    key = _device_key(principal)
    return [*_device_session_ids(key), *(sid for sid, owner in _owners.items() if owner == key)]


# ---------------------------------------------------------------------------
# 模型配置接口的演示视图：设置页与对话框看到的唯一模型就是演示模型
# ---------------------------------------------------------------------------


def provider_views() -> list:
    from movieclaw_api.schemas.llm import LlmProviderView
    from movieclaw_db.models.site_credential import ConfigStatus

    epoch = datetime(2026, 1, 1)
    return [
        LlmProviderView(
            id=0,
            name=DEMO_PROVIDER,
            provider_type="demo",
            default_model=DEMO_MODEL,
            status=ConfigStatus.ACTIVE,
            usable=True,
            available_models=[DEMO_MODEL],
            created_at=epoch,
            updated_at=epoch,
        )
    ]


def model_options() -> list:
    from movieclaw_api.schemas.llm import LlmModelOptionView

    return [
        LlmModelOptionView(
            ref=DEMO_MODEL,
            label=DEMO_MODEL_LABEL,
            model_id=DEMO_MODEL,
            provider_id=0,
            provider_name=DEMO_PROVIDER,
            is_default=True,
        )
    ]


def defaults_view():
    from movieclaw_api.schemas.llm import LlmDefaultsView

    return LlmDefaultsView(
        agent_model=DEMO_MODEL,
        subtitle_model=None,
        effective_agent_model=DEMO_MODEL,
        effective_subtitle_model=None,
    )
