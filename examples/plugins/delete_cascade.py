"""删片联动：在媒体库里删了片子，顺手清掉它的下载器任务和订阅（plugin-extension-model.md §2.1）。

订阅可靠事件 ``library.item.deleted`` / ``library.file.deleted``（删除前的快照，至少一次投递）：

- **整部删除且有订阅**：先 ``subscriptions.delete`` 删订阅（必须先删——订阅还在时删它的种子，
  对应的季集会被打回「想要」重新下载），再逐个删种子；
- **部分删除**（删了几集）：只删**不属于在追订阅**的种子；属于订阅的种子删了会让订阅重新下载
  那几集，那是「删某集重下」，不是清理，交给用户在界面上决定；
- 每个种子都要过安全线：MovieClaw 自己投递的、没有 H&R 风险的、不再供着别的文件的才删；
- ``dry_run: true`` 时只调删除演练，把会发生什么写进日志。

忽略自己引起的事件；同一事件重复投递时，删除操作本身是幂等的。

开启方式（``data/plugins.yaml``；两个删除是危险操作，必须逐个批准）::

    - id: examples.delete-cascade
      local: true
      config: { delete_files: true, dry_run: false }
      grants: [subscriptions.delete, dl.torrent.delete]
"""

from __future__ import annotations

from pydantic import BaseModel, Field

from movieclaw_api.domain_events import LIBRARY_FILE_DELETED, LIBRARY_ITEM_DELETED, LibraryDeleted
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_api.services.host_ops import OpsError
from movieclaw_kernel import DURABLE_EVENTS, Context, plugin


class Config(BaseModel):
    delete_files: bool = Field(default=True, description="删种子时连同下载器里的数据文件一起删")
    dry_run: bool = Field(default=False, description="只演练、写日志，不真删")


def skip_reason(torrent, *, partial: bool, subscription_id: int | None) -> str | None:
    """这个种子为什么不能删；能删返回 None。"""
    if torrent.downloader_id is None:
        return "下载器配置已删除，无从定位"
    if torrent.owned_by_movieclaw is False:
        return "不是 MovieClaw 投递的种子"
    if torrent.hit_and_run:
        return "有 H&R 考核风险"
    if torrent.shared:
        return "还供着没删的文件（季包）"
    if partial and subscription_id is not None and torrent.source == "subscription":
        return "属于在追的订阅（删了会重新下载这几集）"
    return None


@plugin(
    "examples.delete-cascade",
    title="删片联动清理（示例）",
    inject=(DURABLE_EVENTS, HOST_OPS),
    permissions=("subscriptions.delete", "dl.torrent.delete"),
    config=Config,
)
async def delete_cascade(ctx: Context[Config]) -> None:
    config = ctx.config
    ops = await ctx.use(HOST_OPS).client(ctx)
    log = ctx.logger

    async def on_deleted(event: LibraryDeleted) -> None:
        delivery = ctx.delivery
        if delivery is not None and delivery.origin.is_plugin(ctx.entry_id):
            return
        title = event.media.title if event.media else "未知条目"
        subscription_id = event.links.subscription_id
        if event.whole_item and subscription_id is not None:
            if config.dry_run:
                log.info("演练：会删除《%s》的订阅 #%d", title, subscription_id)
            else:
                try:
                    await ops.call("subscriptions.delete", {"subscription_id": subscription_id})
                    log.info("《%s》已删除，订阅 #%d 一并删除", title, subscription_id)
                except OpsError as exc:
                    if exc.status != 404:  # 重复投递时订阅已经没了
                        raise
            subscription_id = None  # 订阅已删：它的种子不会再被打回重下
        for torrent in event.links.torrents:
            reason = skip_reason(
                torrent, partial=not event.whole_item, subscription_id=subscription_id
            )
            if reason is not None:
                log.info("《%s》的种子 %s 保留：%s", title, torrent.info_hash, reason)
                continue
            result = await ops.call(
                "dl.torrent.delete",
                {
                    "downloader_id": torrent.downloader_id,
                    "info_hash": torrent.info_hash,
                    "delete_files": config.delete_files,
                    "dry_run": config.dry_run,
                },
            )
            if config.dry_run:
                log.info(
                    "演练：会删除《%s》的种子 %s（下载器里%s）",
                    title,
                    torrent.info_hash,
                    "有这个任务" if result.get("exists") else "没有这个任务",
                )
            else:
                log.info("《%s》已删除，种子 %s 一并删除", title, torrent.info_hash)

    ctx.on(LIBRARY_ITEM_DELETED, on_deleted, id="item")
    ctx.on(LIBRARY_FILE_DELETED, on_deleted, id="file")
