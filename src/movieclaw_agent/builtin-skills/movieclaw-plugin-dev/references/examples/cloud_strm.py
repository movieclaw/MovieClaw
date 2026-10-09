"""网盘上传 + .strm：入库暂存后把文件传到网盘，媒体库里放一个指向插件自己的 .strm。

对应扩展模型 §2.2（plugin-extension-model.md）。

流程（用户先把导入规则设成「自定义目录」，即暂存目录）：

1. 入库任务把识别、改名好的文件放进暂存目录后，按流水线槽位 ``ingest.staged`` 为本插件建一个
   **上传任务**，挂在入库任务下面（任务中心里能看到父子关系、进度、重试）；
2. 上传任务把文件分块传到网盘（中断后从断点续传），在媒体库根目录下同样的相对位置写一个 ``.strm``，
   内容是本插件公开路由的**签名链接**（不过期，重启、改密都不失效），然后只增量扫描这些目录；
3. 扫描把 ``.strm`` 记账、关闭订阅的想要项——这一段完全是现有流程；
4. 播放时播放器打开 ``.strm`` 里的地址，插件验签通过后把网盘上的文件交出去。

这个示例把「网盘」做成一个本地目录（比如 rclone 挂载点）：上传 = 分块复制，播放 = 从这个目录取流。
换成真实网盘只改两处：``upload_file`` 调网盘的上传接口，``play`` 换出新鲜的直链后 302 跳转。

开启方式（``data/plugins.yaml``）。另需在 设置 → 应用 里配好「外部访问地址」
（``.strm`` 里要写完整地址）::

    - id: examples.cloud-strm
      local: true
      config: { cloud_dir: /mnt/cloud/movieclaw }
      grants: [library.get, library.scan.start]
      paths:   # 文件接口的路径授权（docs/design/plugin-phase3.md §6.2）
        - { path: /mnt/cloud/movieclaw, mode: rw }
        - { path: staging, mode: rw }   # 读暂存文件、上传后删掉暂存副本
        - { path: library, mode: rw }   # 在媒体库里写 .strm
"""

from __future__ import annotations

import asyncio
import hashlib
import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter
from fastapi.responses import Response
from pydantic import BaseModel, Field

from movieclaw_api.exceptions import NotFoundException
from movieclaw_api.pipeline import INGEST_STEPS, IngestStep
from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA, PLUGIN_FILES, PLUGIN_ROUTES
from movieclaw_api.services.host_ops import OpsError
from movieclaw_api.services.jobs import (
    JOB_HANDLERS,
    JobBlocked,
    JobContext,
    JobRetry,
    RegisteredJobHandler,
)
from movieclaw_kernel import Context, plugin


class Config(BaseModel):
    cloud_dir: str = Field(description="网盘目录（示例里是本地目录，例如 rclone 挂载点）")
    chunk_mb: int = Field(default=8, ge=1, le=256, description="上传分块大小")
    keep_staged: bool = Field(default=False, description="上传后保留暂存目录里的副本")


def file_id(relative: str) -> str:
    """网盘文件的稳定 id：同一相对路径重试多少次都是同一个，签出的链接也相同。"""
    return hashlib.sha256(relative.encode("utf-8")).hexdigest()[:20]


def copy_from(src: Any, dst: Any, offset: int, chunk: int) -> None:
    """从 ``offset`` 起把 ``src`` 追加到 ``dst``（两个都是已打开的二进制文件），落盘后返回。"""
    with src, dst:
        src.seek(offset)
        while block := src.read(chunk):
            dst.write(block)
        dst.flush()
        os.fsync(dst.fileno())


async def upload_file(files: Any, source: str, target: str, chunk: int) -> None:
    """分块上传，旁路 ``.part`` 文件记录进度：中断后从已传的字节继续，传完才改名为正式文件。"""
    size = (await files.stat(source))["size"]
    existing = await files.stat(target)
    if existing is not None and existing["size"] == size:
        return
    await files.makedirs(os.path.dirname(target))
    part = f"{target}.part"
    done = (await files.stat(part) or {}).get("size", 0)
    src = await files.open(source, "rb")
    dst = await files.open(part, "ab")
    await asyncio.to_thread(copy_from, src, dst, done, chunk)
    await files.rename(part, target)


async def write_strm(files: Any, path: str, url: str) -> None:
    """临时文件 + 改名：扫描永远看不到写了一半的 .strm。"""
    if await files.exists(path):
        current = await files.open(path, "rb")
        with current:
            if (await asyncio.to_thread(current.read)).decode("utf-8").strip() == url:
                return
    await files.makedirs(os.path.dirname(path))
    tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.tmp")
    out = await files.open(tmp, "wb")
    with out:
        await asyncio.to_thread(out.write, (url + "\n").encode("utf-8"))
    await files.rename(tmp, path)


@plugin(
    "examples.cloud-strm",
    title="网盘上传与 .strm（示例）",
    inject=(HOST_OPS, PLUGIN_DATA, PLUGIN_FILES, PLUGIN_ROUTES),
    permissions=("library.get", "library.scan.start"),
    config=Config,
)
async def cloud_strm(ctx: Context[Config]) -> None:
    config = ctx.config
    cloud = Path(config.cloud_dir)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    # 文件一律经文件接口：读暂存、写网盘、写 .strm 都要在 plugins.yaml 的 paths 里批准过
    files = ctx.use(PLUGIN_FILES).scoped(ctx)
    routes = ctx.use(PLUGIN_ROUTES)
    ops = await ctx.use(HOST_OPS).client(ctx)
    log = ctx.logger

    # ---- 播放入口：公开区，宿主先验签，签名不对一律 404 ---------------------------
    router = APIRouter()

    @router.get(
        "/play/{fid}",
        operation_id=f"plugins.{ctx.entry_id}.play",
        summary="播放网盘上的文件（.strm 指向这里）",
    )
    async def play(fid: str) -> Response:
        relative = await store.get(f"file:{fid}")
        if relative is None:
            raise NotFoundException("网盘上找不到这个文件")
        # 交出文件由宿主发送（支持 Range）；真实网盘在这里换出新鲜直链后 302 跳转
        return files.response(cloud / relative)

    routes.mount(ctx, router, zone="public")

    # ---- 上传任务 ---------------------------------------------------------------
    async def upload(context: JobContext, data: dict[str, Any]) -> dict[str, Any]:
        library_id = data.get("library_id")
        if library_id is None:
            raise JobBlocked("这批文件没有对应的媒体库，.strm 无处可放；请先建一个对应类型的媒体库")
        try:
            library = await ops.call("library.get", {"library_id": library_id})
        except OpsError as exc:
            raise JobRetry(f"读取媒体库失败：{exc.message}", delay_seconds=60) from exc
        root = Path(library["primary_root"])
        staging = Path(data["rule"]["target_path"])
        batch = data["files"]
        written: list[str] = []
        for index, item in enumerate(batch, start=1):
            source = Path(item["path"])
            relative = source.relative_to(staging).as_posix()
            strm = str((root / relative).with_suffix(".strm"))
            if await files.exists(source):
                try:
                    await upload_file(
                        files, str(source), str(cloud / relative), config.chunk_mb * 1024 * 1024
                    )
                except PermissionError as exc:
                    raise JobBlocked(
                        f"{exc}；请在 plugins.yaml 的 paths 里批准网盘目录、staging 与 library"
                    ) from exc
                except OSError as exc:
                    raise JobRetry(f"上传 {source.name} 失败：{exc}", delay_seconds=60) from exc
                fid = file_id(relative)
                await store.set(f"file:{fid}", relative)
                try:
                    url = await routes.sign(ctx, f"/play/{fid}", absolute=True)
                except ValueError as exc:
                    raise JobBlocked(
                        str(exc),
                        actions=[{"type": "open_settings", "label": "去配置", "target": "app"}],
                    ) from exc
                await write_strm(files, strm, url)
                if not config.keep_staged:
                    await files.remove(source)
            elif not await files.exists(strm):
                raise JobBlocked(f"暂存文件不见了，也没有写出 .strm：{source}")
            # 否则是重试：这个文件上一轮已经传完、写好了
            written.append(strm)
            await context.update_progress(
                mode="determinate",
                phase="upload",
                message=f"已上传 {index}/{len(batch)}：{source.name}",
                current=index,
                total=len(batch),
            )
        scope = sorted({str(Path(p).parent) for p in written})
        try:
            # 请求体可选的操作，请求体整体作为 body 参数传
            await ops.call(
                "library.scan.start", {"library_id": library_id, "body": {"paths": scope}}
            )
        except OpsError as exc:
            if exc.status == 409:  # 媒体库正忙（扫描 / 整理中），稍后再触发
                raise JobRetry(f"媒体库正忙：{exc.message}", delay_seconds=60) from exc
            raise
        log.info("《%s》%d 个文件已上传网盘并写好 .strm", data["media"]["title"], len(written))
        return {"strm": written}

    ctx.contribute(JOB_HANDLERS, "upload", RegisteredJobHandler(upload, frozenset({1})))
    ctx.contribute(
        INGEST_STEPS, "upload", IngestStep(job_type=f"{ctx.entry_id}:upload", title="上传网盘")
    )
