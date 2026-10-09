"""片单订阅：盯着一个外部片单，新出现的片名自动订阅（docs/design/plugin-extension-model.md §2.4）。

片单可以是一个 URL（JSON 数组、``{"titles": [...]}`` 或一行一个片名的纯文本），也可以是本机文件
（经文件接口读取，须在 ``paths`` 里批准它所在的目录）。
每轮把没处理过的片名交给宿主操作 ``search.titles`` 解析成作品，再 ``subscriptions.create`` 订阅：
豆瓣条目对应多个 TMDB 条目时（409）取第一个候选；创建订阅本身对同一作品幂等。
处理过的片名记在插件数据里（``PLUGIN_DATA``），重复信号不会重复订阅。

开启方式（``data/plugins.yaml``）::

    - id: examples.watchlist-feed
      local: true
      config:
        source: https://example.com/my-watchlist.json
        interval_minutes: 30
      grants: [search.titles, subscriptions.create]
      # 片单是本机文件时：paths: [{ path: /volume1/lists, mode: read }]
"""

from __future__ import annotations

import asyncio
import json

import httpx
from pydantic import BaseModel, Field

from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_FILES
from movieclaw_api.services.host_ops import OpsError
from movieclaw_kernel import Context, plugin


class Config(BaseModel):
    source: str = Field(description="片单地址（http/https）或本机文件路径")
    interval_minutes: float = Field(default=30, gt=0)
    provider: str = Field(default="all", description="search.titles 的来源：all / tmdb / douban")


def parse_titles(text: str) -> list[str]:
    """片单正文 → 片名列表（去空白、去重、保持顺序）。"""
    try:
        data = json.loads(text)
    except ValueError:
        data = text.splitlines()
    if isinstance(data, dict):
        data = data.get("titles") or []
    titles = [str(item).strip() for item in data if str(item).strip()]
    return list(dict.fromkeys(titles))


@plugin(
    "examples.watchlist-feed",
    title="片单订阅（示例）",
    inject=(HOST_OPS, PLUGIN_DATA, PLUGIN_FILES),
    permissions=("search.titles", "subscriptions.create"),
    config=Config,
)
async def watchlist_feed(ctx: Context[Config]) -> None:
    config = ctx.config
    ops = await ctx.use(HOST_OPS).client(ctx)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    files = ctx.use(PLUGIN_FILES).scoped(ctx)
    log = ctx.logger

    async def load_done() -> set[str]:
        return set(await store.get("done", default=[]))

    async def save_done(done: set[str]) -> None:
        await store.set("done", sorted(done))

    async def fetch() -> str:
        if config.source.startswith(("http://", "https://")):
            async with httpx.AsyncClient(timeout=20) as client:
                response = await client.get(config.source)
                response.raise_for_status()
                return response.text
        source = await files.open(config.source, "rb")
        with source:
            return (await asyncio.to_thread(source.read)).decode("utf-8")

    async def subscribe(title: str) -> str | None:
        """返回结果描述；找不到作品返回 None（下一轮再试）。"""
        found = await ops.call(
            "search.titles", {"query": title, "provider": config.provider, "save_history": False}
        )
        candidates = found.get("titles") or []
        if not candidates:
            return None
        title_ref = candidates[0]["title_ref"]
        try:
            created = await ops.call("subscriptions.create", {"title_ref": title_ref})
        except OpsError as exc:
            if exc.code != "SUBSCRIPTION_TARGET_AMBIGUOUS" or not exc.details:
                raise
            # 豆瓣条目对应多个 TMDB 条目：取第一个候选，并保留豆瓣来源
            created = await ops.call(
                "subscriptions.create",
                {"title_ref": exc.details[0]["title_ref"], "source_title_ref": title_ref},
            )
        subscription = (created or {}).get("subscription") or {}
        return f"已订阅（#{subscription.get('id')}）"

    async def sync_once() -> None:
        titles = parse_titles(await fetch())
        done = await load_done()
        for title in titles:
            if title in done:
                continue
            try:
                result = await subscribe(title)
            except OpsError as exc:
                log.warning("片单里的《%s》订阅失败：%s", title, exc.message)
                continue
            if result is None:
                log.info("片单里的《%s》暂时搜不到对应作品，下一轮再试", title)
                continue
            done.add(title)
            await save_done(done)
            log.info("片单里的《%s》%s", title, result)

    async def poll() -> None:
        while True:
            try:
                await sync_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 -- 片单暂时不可达，下一轮再来
                log.warning("拉取片单失败：%s", config.source, exc_info=True)
            await asyncio.sleep(config.interval_minutes * 60)

    ctx.task(poll(), name="poll")
