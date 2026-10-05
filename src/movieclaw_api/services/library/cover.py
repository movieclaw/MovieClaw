"""库封面拼贴——服务端渲染的「氛围光货架」（双端共用）。

复刻控制台 LibraryCover 组件（apps/web/components/library-view.tsx）的构图，
让 Jellyfin 兼容层（播放器库卡片）与控制台媒体库页显示**同一张**真实图片：

- 画布 21:10；氛围光 = 首张海报放大重模糊提饱和铺满，再压暗保证前景对比；
- 至多 4 张海报（各占画布宽 22.5%，2:3 竖版，圆角 + 白描边 + 落影）立排；
- 每张海报下方带向下渐隐的倒影；底部一枚中性地面光斑像射灯打在舞台上。

素材选择：库内有本地海报资产、**今天零点之前**最近入库的 4 部作品（不足 4 部
才拿今天入库的补位，补位先到先占）。产物落 data/metadata/library-covers/{库id}-{key}.jpg，
key 由海报路径+mtime 派生，旧文件顺手清理。渲染是 CPU 活，统一走
asyncio.to_thread，不堵事件循环。

**一天最多换一次图**：以前按"最近入库的 4 部"选，订阅一天进十部片就重渲十次
（NAS 上一张约 1 秒），每次请求还要重扫全库入库记录。现在：
- 素材以零点为界，当天新入库的片不影响选择，过了零点统一换一次；
- 选好的封面登记在进程内存里，当天有效，请求只做一次字典查找加一次 stat；
- **只冻结满一架的封面**：空库、不满 4 张的新库每次请求都重选，新片当场补上
  （库小，查询便宜；选择真变了才重渲，从空到满至多渲 4 次）；
- 登记带着库内容版本（``stats_refreshed_at``）：入库、删除、回收、扫描对账后
  重选一次——今天的新片不参与选择，满架库选出来还是那几部，不重渲；选中的片被
  移走、库空了，封面当场跟上；
- 只有过零点与进程重启（内容没变、只是日子换了，一批库同时换图）先给上一版、
  后台再渲，请求不等 Pillow。

用户上传的**自定义封面**优先于拼贴（issue #427）：本模块是三端封面的唯一
入口（控制台卡片、管理页缩略图、Jellyfin 库 Primary 图），自定义封面在
``ensure_library_cover`` 的最前面短路，下游一处都不用改。
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import re
import time
from collections.abc import Callable, Hashable
from dataclasses import dataclass
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

from sqlalchemy import func, select

from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile, MediaMetadata

logger = logging.getLogger("movieclaw_api.library_cover")

# 画布：控制台卡片是 21/10 比例；1260x600 对 2x 屏的卡片宽度绰绰有余
CANVAS_W, CANVAS_H = 1260, 600
POSTER_W_RATIO = 0.225  # 单张海报占画布宽
POSTER_GAP_RATIO = 0.02
POSTER_TOP_RATIO = 0.045
MAX_POSTERS = 4

# 同一库的封面选择、素材指纹计算和 Pillow 渲染必须作为一个整体去重。根级
# Items 与库图片接口会并发调用本服务；仅锁渲染仍会让每个请求重复扫描候选素材。
_cover_tasks: dict[int, asyncio.Task[tuple[Path, str] | None]] = {}
# 后台渲染中的拼贴（按产物路径去重），供「先给旧图」的路径用
_render_tasks: dict[Path, asyncio.Task[None]] = {}


# ---------------------------------------------------------------------------
# 按天登记：今天选定的封面记在内存里，零点作废
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Memo:
    cutoff: datetime
    path: Path
    key: str
    #: 满一架（MAX_POSTERS 张）才冻结到零点；不满的每次请求都重选——空库/新库
    #: 进了新片要当场上封面，不能等到明天
    full: bool
    #: 登记时的库内容版本（``library.stats_refreshed_at``）；对不上就重选
    version: object = None


_memos: dict[Hashable, _Memo] = {}


def _now() -> datetime:
    """当前时刻（带时区，按定时任务那个时区）。单独一个函数，测试可以拨钟。"""
    try:
        tz = ZoneInfo(get_settings().scheduler_timezone)
    except Exception:  # 时区配错时退回本机时区，不让封面挂掉
        return datetime.now().astimezone()
    return datetime.now(tz)


def day_cutoff() -> datetime:
    """今天零点（naive UTC，与 created_at 同一口径）。"""
    midnight = _now().replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.astimezone(UTC).replace(tzinfo=None)


def _memo_usable(memo: _Memo | None) -> bool:
    # 产物得还在、且在当前的封面目录里（数据目录换过就不认旧登记）
    return memo is not None and memo.path.parent == covers_dir() and memo.path.is_file()


def memo_get(
    key: Hashable,
    version: object = None,
    *,
    still_valid: Callable[[object], bool] | None = None,
) -> tuple[Path, str] | None:
    """今天登记过、满一架、内容版本没变、产物还在的封面；否则返回 None（调用方重选）。

    ``still_valid`` 代替「版本相等」的判定：拿登记时的版本自己核对（「合集」视图
    用它核对组成封面的合集是否都还在）。"""
    memo = _memos.get(key)
    if memo is None or not memo.full or memo.cutoff != day_cutoff():
        return None
    valid = still_valid(memo.version) if still_valid is not None else memo.version == version
    if not valid:
        return None
    return (memo.path, memo.key) if _memo_usable(memo) else None


def _memo_stale(key: Hashable, *, full_only: bool = False) -> tuple[Path, str] | None:
    """登记过的上一版（不论哪天），产物还在就能先顶上。

    ``full_only``：只认满一架的上一版。不满一架的库在长新片，换图要当场渲——
    先给旧图的话，客户端缓存了旧 tag，新片就迟迟上不了封面。"""
    memo = _memos.get(key)
    if memo is None or (full_only and not memo.full) or not _memo_usable(memo):
        return None
    return memo.path, memo.key


def _memo_put(
    key: Hashable,
    result: tuple[Path, str],
    poster_count: int,
    *,
    cutoff: datetime | None = None,
    version: object = None,
) -> None:
    """登记今天的封面。``cutoff`` 传选素材那一刻的分界：查询期间跨过零点时，
    昨天口径的结果只能算昨天的，不能冻结一整天。``version`` 是选素材前读到的
    库内容版本。"""
    stamp = cutoff if cutoff is not None else day_cutoff()
    _memos[key] = _Memo(stamp, result[0], result[1], poster_count >= MAX_POSTERS, version)


# 「合集」视图换下来的旧图留多久：客户端会缓存 /UserViews，拿着旧 tag 来取图时
# 不能 404（#587 的空白格子）；Infuse 启动就会刷新视图，一周绰绰有余
_VIEW_COVER_GRACE_SECONDS = 7 * 86400


def _sweep_view_covers() -> None:
    """清掉没有观看范围在用、且超过宽限期的「合集」视图旧图。"""
    in_use = {memo.path for memo in _memos.values()}
    horizon = time.time() - _VIEW_COVER_GRACE_SECONDS
    for path in covers_dir().glob(f"{_COLLECTIONS_VIEW_STEM}-*.jpg"):
        try:
            if path not in in_use and path.stat().st_mtime < horizon:
                path.unlink(missing_ok=True)
        except OSError:
            continue


# ---------------------------------------------------------------------------
# 自定义封面（用户上传）
#
# 存 **uploads** 而不是 metadata：metadata/library-covers 在存储登记里是可清理
# 的缓存（拼贴随时能重渲），用户自己做的图清掉就没了。uploads 是不可清理的
# 用户数据组，语义才对（services/storage/registry.py 的 uploads 条目已覆盖此
# 子目录，登记项不得嵌套，故不新增条目）。
#
# 一库一槽位：data/uploads/library-covers/{库id}.jpg。"有没有自定义封面" =
# 文件在不在，不加数据库列、不做迁移（与首页背景图同一套思路）。
# ---------------------------------------------------------------------------

# 收前硬闸：与首页背景图一致。前端会先压一道，这里是防滥用的下限
MAX_UPLOAD_BYTES = 10 * 1024 * 1024
# 解压炸弹防线：10MB 的 PNG 能解出几个 GB 的位图。先看 size 再解码，
# Image.open 只读文件头、不触碰像素，这一步零成本
MAX_UPLOAD_PIXELS = 50_000_000
# 长边上限：卡片在 2 倍屏上也就 800 逻辑像素宽，拼贴本体才 1260 宽，
# 1600 已经绰绰有余；再大只是白占磁盘和带宽
CUSTOM_MAX_EDGE = 1600
# JPEG 而非 WebP：Jellyfin 图片路由本就按 image/jpeg 输出，第三方播放器
# （VidHub / Infuse / Emby 系）对 WebP 支持参差，省下的两成体积换不来
# "封面不显示"这类难排查的报障
CUSTOM_JPEG_QUALITY = 85
# 透明图压到 JPEG 必须先填底；用货架背景同色，观感连续
_FLATTEN_BG = (8, 10, 16)


def custom_covers_dir() -> Path:
    return Path(get_settings().media_dir) / "library-covers"


def custom_cover_path(library_id: int) -> Path:
    return custom_covers_dir() / f"{library_id}.jpg"


def has_custom_cover(library_id: int) -> bool:
    """该库是否设了自定义封面（库视图据此决定按钮形态与空库要不要出图）。"""
    return custom_cover_path(library_id).is_file()


def _custom_cover_entry(library_id: int) -> tuple[Path, str] | None:
    """自定义封面的 (路径, 版本 key)；没有则 None。

    key 与拼贴同形（32 位 hex）——Jellyfin 客户端拿它当 ImageTags.Primary，
    换个形状不值得赌各家实现的宽容度。内容变了 key 就变，缓存自动失效。
    """
    path = custom_cover_path(library_id)
    try:
        mtime = path.stat().st_mtime_ns
    except OSError:
        return None
    return path, hashlib.md5(f"custom:{path}:{mtime}".encode()).hexdigest()


def normalize_cover_image(data: bytes) -> bytes:
    """把用户上传的任意图片归一化成一张「小而够用」的 JPEG 封面。

    纯 CPU 同步函数，调用方负责丢 asyncio.to_thread。手机原图/4K 截图
    通常 5~10MB，过一遍这里落到 100~300KB 量级（实测降 97% 以上）。

    做了这些事（顺序有讲究）：
    1. **真解码**，不信客户端报的 Content-Type——MIME 是上传方说了算的，
       顺带把可内嵌脚本的 SVG 挡在门外（Pillow 根本不认它）；
    2. 像素数超限直接拒，防解压炸弹；
    3. 按 EXIF 摆正，否则手机横拍的封面是躺着的；
    4. 长边缩到 1600（只缩不放，LANCZOS）；
    5. 透明通道合到深色底上（JPEG 没有 alpha）；
    6. 重编码为渐进式 JPEG——顺带把 EXIF（含 GPS）一起丢掉。

    **不裁剪**：各消费方本来就 object-cover 自己裁，用户精心做的图不该被
    我们先切一刀。

    校验失败抛 ``ValueError``，消息是给非开发者看的中文，路由层直接转 400。
    """
    from PIL import Image, ImageOps

    try:
        img = Image.open(BytesIO(data))
    except Exception as exc:  # Pillow 对坏文件抛的异常类型不止一种
        raise ValueError("无法识别这个文件，请上传 JPG / PNG / WebP 等常见格式的图片") from exc

    width, height = img.size
    if width * height > MAX_UPLOAD_PIXELS:
        # 上限跟着常量走，别把数字写死在文案里——改了常量提示就撒谎了
        raise ValueError(
            f"图片尺寸过大（{width}×{height}），"
            f"请先缩小到 {MAX_UPLOAD_PIXELS // 10_000} 万像素以内再上传"
        )

    try:
        img = ImageOps.exif_transpose(img) or img
        if img.mode in ("RGBA", "LA", "P"):
            rgba = img.convert("RGBA")
            base = Image.new("RGBA", rgba.size, (*_FLATTEN_BG, 255))
            img = Image.alpha_composite(base, rgba).convert("RGB")
        else:
            img = img.convert("RGB")
        img.thumbnail((CUSTOM_MAX_EDGE, CUSTOM_MAX_EDGE), Image.LANCZOS)
        buffer = BytesIO()
        img.save(
            buffer,
            "JPEG",
            quality=CUSTOM_JPEG_QUALITY,
            optimize=True,
            progressive=True,
        )
    except Exception as exc:
        raise ValueError("这张图片处理失败，可能已损坏或格式不受支持，请换一张试试") from exc

    out = buffer.getvalue()
    logger.info(
        "自定义封面已压缩：%d×%d %d 字节 → %d×%d %d 字节",
        width,
        height,
        len(data),
        img.width,
        img.height,
        len(out),
    )
    return out


def _drop_collage(library_id: int) -> None:
    """清掉该库的拼贴产物——设了自定义封面就再没人读它了，留着白占磁盘。"""
    out_dir = covers_dir()
    if not out_dir.is_dir():
        return
    for stale in out_dir.glob(f"{library_id}-*.jpg"):
        stale.unlink(missing_ok=True)


def save_custom_cover(library_id: int, image: bytes) -> str:
    """把**已归一化**的封面落盘并返回新的版本 key（调用方拿去打缓存）。

    先写临时文件再 ``os.replace`` 原子换上：换图的同时可能正有请求在读这张图，
    直接覆写会露出截断的半张；中途崩溃也会留下一张永久损坏的封面。
    """
    target = custom_cover_path(library_id)
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_suffix(f".{uuid4().hex}.tmp")
    try:
        staging.write_bytes(image)
        os.replace(staging, target)
    finally:
        staging.unlink(missing_ok=True)
    _drop_collage(library_id)
    entry = _custom_cover_entry(library_id)
    logger.info("媒体库 #%d 已设置自定义封面：%s（%d 字节）", library_id, target, len(image))
    # 刚写完必然存在；真被并发删了就退回一个稳定占位，调用方只拿它打缓存
    return entry[1] if entry else ""


def remove_custom_cover(library_id: int) -> bool:
    """删除自定义封面，回落到自动拼贴；返回是否确有文件被删。"""
    target = custom_cover_path(library_id)
    if not target.is_file():
        return False
    target.unlink(missing_ok=True)
    logger.info("媒体库 #%d 的自定义封面已删除，封面回落到自动拼贴", library_id)
    return True


def covers_dir() -> Path:
    return Path(get_settings().metadata_dir) / "library-covers"


def _assets_root() -> Path:
    from movieclaw_api.services.media_scrape import assets_root

    return Path(assets_root())


async def select_cover_posters(library_id: int, cutoff: datetime | None = None) -> list[Path]:
    """选出该库至多 4 部作品的海报绝对路径：有本地海报资产、今天零点之前最近入库的
    优先，不足 4 部再拿今天入库的补位（新库当天也有封面）。

    补位按**入库先后**取，先到先占：今天陆续进的片只会往后排，凑满一架后当天
    不会被后来的挤掉（新库当天全是今天的片，按最新优先的话每进一部都要换图）。
    过了零点它们成了「之前入库的」，再按最新优先轮换。

    同一入库时间按作品 id 定序——批量扫描入库的时间戳可能挨得很近，没有第二
    排序键的话选出哪几部取决于数据库内部顺序，封面会无故来回换。
    """
    root = _assets_root()
    if cutoff is None:
        cutoff = day_cutoff()
    async with get_database().session() as session:
        # 只需要海报路径与入库时间：整行读取会反序列化每部作品的简介、演员等
        # 大字段；VidHub 的根级 Items 每次启动都会走这里，大库上代价不可接受。
        rows = (
            await session.execute(
                select(
                    MediaMetadata.poster_file,
                    func.max(LibraryFile.created_at).label("latest_created_at"),
                )
                .join(
                    LibraryFile,
                    LibraryFile.media_item_id == MediaMetadata.media_item_id,
                )
                .where(
                    LibraryFile.library_id == library_id,
                    LibraryFile.in_place(),
                    MediaMetadata.poster_file.is_not(None),
                )
                .group_by(MediaMetadata.media_item_id, MediaMetadata.poster_file)
                .order_by(
                    func.max(LibraryFile.created_at).desc(),
                    MediaMetadata.media_item_id.desc(),
                )
            )
        ).all()
    ordered = [rel for rel, latest in rows if latest < cutoff]
    ordered += [rel for rel, latest in reversed(rows) if latest >= cutoff]
    result: list[Path] = []
    for rel in ordered:
        path = root / rel
        if path.is_file():
            result.append(path)
        if len(result) >= MAX_POSTERS:
            break
    return result


def _cover_key(paths: list[Path]) -> str:
    hasher = hashlib.md5()
    for p in paths:
        try:
            hasher.update(f"{p}:{p.stat().st_mtime_ns};".encode())
        except OSError:
            hasher.update(f"{p}:gone;".encode())
    return hasher.hexdigest()


def _clear_cover_task(
    library_id: int, task: asyncio.Task[tuple[Path, str] | None]
) -> None:
    """仅移除当前任务，避免完成回调误删后续同库任务。

    后台刷新（先给了旧图）没有人 await，异常在这里取走记一笔，免得事件循环
    报 "Task exception was never retrieved"。"""
    if _cover_tasks.get(library_id) is task:
        _cover_tasks.pop(library_id, None)
    if not task.cancelled() and (exc := task.exception()) is not None:
        logger.warning("库封面刷新失败（library_id=%d）：%s", library_id, exc)


def _newest_collage(library_id: int) -> tuple[Path, str] | None:
    """盘上该库最新的一张拼贴（进程重启后内存登记没了，靠它先顶上）。"""
    out_dir = covers_dir()
    if not out_dir.is_dir():
        return None
    found: list[tuple[float, Path]] = []
    for path in out_dir.glob(f"{library_id}-*.jpg"):
        try:
            found.append((path.stat().st_mtime, path))
        except OSError:
            continue
    if not found:
        return None
    path = max(found)[1]
    return path, path.stem.split("-", 1)[1]


_UNSET: object = object()


async def library_content_version(library_id: int) -> object:
    """库内容版本：``stats_refreshed_at``。入库、回收、扫描对账、转移……所有改变
    库内容的写路径收尾都会重算统计并刷新它，正好拿来判断当天登记还作不作数。"""
    from movieclaw_db.models import Library

    async with get_database().session() as session:
        query = select(Library.stats_refreshed_at).where(Library.id == library_id)
        return (await session.execute(query)).scalar_one_or_none()


async def ensure_library_cover(
    library_id: int, content_version: object = _UNSET
) -> tuple[Path, str] | None:
    """返回该库封面的 (文件路径, 版本 key)；没有可用封面返回 None。

    **自定义封面优先**：用户上传过就直接给他的图，一次 stat 的成本，连拼贴
    的候选素材都不用扫（issue #427）。

    没有自定义封面才走拼贴：今天登记过（满一架、库内容没变）就直接给；否则起一个
    刷新任务（选素材 → 指纹命中直接用，否则重渲并清理旧产物）。只有**过零点**与
    **进程重启**这两种「内容没变、只是日子换了」的情况先给上一版、后台刷新——
    那是一批库同时换图的时刻；库内容变了（新片补位、选中的片被移走、库空了）或
    一张都没有时等刷新完成，封面当场跟上。同一库的并发调用复用同一任务，避免
    重复扫描海报或重复执行 Pillow 渲染。

    ``content_version``：调用方手上有库行时传 ``library.stats_refreshed_at``，
    省一次查询；不传就现查。
    """
    custom = _custom_cover_entry(library_id)
    if custom is not None:
        return custom
    if content_version is _UNSET:
        content_version = await library_content_version(library_id)
    memo_key = ("library", library_id)
    hit = memo_get(memo_key, content_version)
    if hit is not None:
        return hit
    task = _cover_tasks.get(library_id)
    if task is None:
        task = asyncio.create_task(_ensure_library_cover_once(library_id, content_version))
        _cover_tasks[library_id] = task
        task.add_done_callback(lambda done: _clear_cover_task(library_id, done))
    if not task.done():
        memo = _memos.get(memo_key)
        if memo is None:
            # 内存登记没了（进程刚重启）：盘上那张先顶上
            stale = _newest_collage(library_id)
        elif memo.version == content_version:
            # 只是过了零点：满一架的上一版先顶上
            stale = _memo_stale(memo_key, full_only=True)
        else:
            stale = None
        if stale is not None:
            return stale
    # 单个 HTTP 请求断开时，不应取消其他请求正在等待的共享封面生成。
    return await asyncio.shield(task)


async def _ensure_library_cover_once(
    library_id: int, content_version: object = None
) -> tuple[Path, str] | None:
    """执行一次完整的封面选择、缓存检查和渲染流程，结果登记到今天。"""
    memo_key = ("library", library_id)
    cutoff = day_cutoff()
    posters = await select_cover_posters(library_id, cutoff=cutoff)
    if not posters:
        # 库空了（片全移走 / 海报都没了）：旧图一并清掉——留在盘上的话，重启后
        # 「盘上那张先顶上」会让一个空库永远挂着旧封面
        _memos.pop(memo_key, None)
        _drop_collage(library_id)
        return None
    key = _cover_key(posters)
    out_dir = covers_dir()
    target = out_dir / f"{library_id}-{key}.jpg"
    if not target.is_file():
        out_dir.mkdir(parents=True, exist_ok=True)
        # 原子替换：刷新期间别的请求正拿着上一版，半张图不能露出去
        temp = target.with_name(f"{target.stem}-{uuid4().hex}.tmp")
        try:
            await asyncio.to_thread(render_shelf_collage, posters, temp)
            os.replace(temp, target)
        except Exception:
            logger.exception("库封面拼贴渲染失败（library_id=%d）", library_id)
            # 有上一版就接着用到明天，不让每个请求都重试一次 1 秒的渲染
            stale = _memo_stale(memo_key) or _newest_collage(library_id)
            if stale is not None:
                _memo_put(memo_key, stale, MAX_POSTERS, cutoff=cutoff, version=content_version)
            return stale
        finally:
            temp.unlink(missing_ok=True)
        for stale_file in out_dir.glob(f"{library_id}-*.jpg"):
            if stale_file != target:
                stale_file.unlink(missing_ok=True)
    _memo_put(memo_key, (target, key), len(posters), cutoff=cutoff, version=content_version)
    return target, key


def forget_library_cover(library_id: int) -> None:
    """删库时把封面全部带走：自定义封面、拼贴产物、当天登记。

    SQLite 的主键不带 AUTOINCREMENT，被删的最大 id 会复用给下一个新建的库——
    留下任何一样，新库都会顶着旧库的封面。"""
    remove_custom_cover(library_id)
    _drop_collage(library_id)
    _memos.pop(("library", library_id), None)


async def ensure_collection_cover(
    collection_id: int, poster_files: list[str]
) -> tuple[Path, str] | None:
    """用当前观看者可见的素材渲染合集封面，复用真实库的货架构图。

    缓存指纹包含素材路径和版本，不同权限范围的封面不会串用；产物沿用已登记的
    library-covers 缓存目录。不同观看者的产物可并存，不能按合集 id 清理彼此的缓存。
    """
    return await _ensure_poster_collage(f"collection-{collection_id}", poster_files)


_COLLECTIONS_VIEW_STEM = "collections"
_KEY_RE = re.compile(r"[0-9a-f]{32}")


async def ensure_collections_view_cover(
    poster_files: list[str], *, memo_key: Hashable, version: object = None
) -> tuple[Path, str] | None:
    """Jellyfin 顶层「合集」视图的封面：每个可见合集出一张封面海报，同一种货架构图。

    素材由调用方按观看者权限选好（取图请求不带凭据，只能凭 tag 找回这里的产物）。
    ``memo_key`` 标识观看范围：结果登记到今天，调用方先 ``memo_get`` 命中就不必
    再选素材；换图时先给这个范围的上一版、后台再渲。``version`` 记组成封面的合集，
    供调用方核对它们是否都还在。
    """
    return await _ensure_poster_collage(
        _COLLECTIONS_VIEW_STEM, poster_files, memo_key=memo_key, version=version
    )


def collections_view_cover(key: str) -> Path | None:
    """按 tag（即素材指纹）找回已渲染的「合集」视图封面；没有或 tag 不合法返回 None。"""
    if not _KEY_RE.fullmatch(key):
        return None
    path = covers_dir() / f"{_COLLECTIONS_VIEW_STEM}-{key}.jpg"
    return path if path.is_file() else None


async def _ensure_poster_collage(
    stem: str,
    poster_files: list[str],
    *,
    memo_key: Hashable | None = None,
    version: object = None,
) -> tuple[Path, str] | None:
    """把资产相对路径列表渲染成 ``{stem}-{素材指纹}.jpg``，返回 (文件, 指纹)。

    给了 ``memo_key``：结果登记到今天；要重渲而这个 key 有满一架、构成相同的上一版
    时先返回上一版，渲染丢到后台（不满一架或构成变了的当场渲，同库封面）。"""
    root = _assets_root().resolve()
    posters = []
    for rel in poster_files:
        path = (root / rel).resolve()
        if path.is_relative_to(root) and path.is_file():
            posters.append(path)
        if len(posters) >= MAX_POSTERS:
            break
    if not posters:
        return None
    key = _cover_key(posters)
    target = covers_dir() / f"{stem}-{key}.jpg"
    if not target.is_file():
        # 只有构成没变（同一批素材来源，只是过了零点或海报换了版本）才先给上一版；
        # 构成变了（新合集补位、合集被删）当场渲，同库封面
        memo = _memos.get(memo_key) if memo_key is not None else None
        stale = (
            _memo_stale(memo_key, full_only=True)
            if memo is not None and memo.version == version
            else None
        )
        task = _render_tasks.get(target)
        if task is None:
            task = asyncio.create_task(_render_collage(stem, posters, target))
            _render_tasks[target] = task
            task.add_done_callback(lambda _done: _render_tasks.pop(target, None))
        if stale is not None:
            return stale
        await asyncio.shield(task)
        if not target.is_file():
            return None
    if memo_key is not None:
        _memo_put(memo_key, (target, key), len(posters), version=version)
    return target, key


async def _render_collage(stem: str, posters: list[Path], target: Path) -> None:
    """渲染一张拼贴；失败只记日志（调用方按产物在不在判断）。"""
    target.parent.mkdir(parents=True, exist_ok=True)
    # 原子替换：Web 与 App 同时请求时也不会读到尚未写完的 JPEG。
    temp = target.with_name(f"{target.stem}-{uuid4().hex}.tmp")
    try:
        await asyncio.to_thread(render_shelf_collage, posters, temp)
        os.replace(temp, target)
    except Exception:
        logger.exception("合集封面拼贴渲染失败（%s）", stem)
    finally:
        temp.unlink(missing_ok=True)
    if stem == _COLLECTIONS_VIEW_STEM:
        _sweep_view_covers()


def render_shelf_collage(poster_paths: list[Path], out: Path) -> None:
    """Pillow 渲染「氛围光货架」。纯同步，调用方负责丢线程池。"""
    from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

    def load_poster(path: Path, width: int) -> Image.Image:
        img = Image.open(path).convert("RGB")
        height = round(width * 3 / 2)
        # cover 语义裁剪到 2:3
        scale = max(width / img.width, height / img.height)
        img = img.resize((round(img.width * scale), round(img.height * scale)))
        left = (img.width - width) // 2
        top = (img.height - height) // 2
        return img.crop((left, top, left + width, top + height))

    canvas = Image.new("RGB", (CANVAS_W, CANVAS_H), "#080a10")

    # ---- 氛围光底：首图 cover 铺满 → 放大 1.5x → 重模糊 → 提饱和 → 压暗 ----
    first = Image.open(poster_paths[0]).convert("RGB")
    scale = max(CANVAS_W / first.width, CANVAS_H / first.height) * 1.5
    ambient = first.resize((round(first.width * scale), round(first.height * scale)))
    left = (ambient.width - CANVAS_W) // 2
    top = (ambient.height - CANVAS_H) // 2
    ambient = ambient.crop((left, top, left + CANVAS_W, top + CANVAS_H))
    ambient = ambient.filter(ImageFilter.GaussianBlur(56))
    ambient = ImageEnhance.Color(ambient).enhance(1.5)
    canvas = Image.blend(canvas, ambient, 0.7)  # 首图 opacity 0.7 落在深底上
    dark = Image.new("RGB", canvas.size, "#080a10")
    canvas = Image.blend(canvas, dark, 0.5)  # bg-[#080a10]/50 压暗

    # ---- 灯箱底光：首图模糊自底向上 screen 发光（颜色天然取自海报主色）----
    glow_h = CANVAS_H // 2
    glow = ambient.resize((CANVAS_W, glow_h)).filter(ImageFilter.GaussianBlur(40))
    glow = ImageEnhance.Color(glow).enhance(1.4)
    from PIL import ImageChops

    region = canvas.crop((0, CANVAS_H - glow_h, CANVAS_W, CANVAS_H))
    screened = ImageChops.screen(region, glow)
    # 自底向上的线性渐隐（底边最亮 0.55 → 顶部 0）
    mask = Image.new("L", (CANVAS_W, glow_h))
    mask_draw = ImageDraw.Draw(mask)
    for y in range(glow_h):
        mask_draw.line(
            [(0, y), (CANVAS_W, y)], fill=round(255 * 0.55 * (y / glow_h))
        )
    region.paste(screened, (0, 0), mask)
    canvas.paste(region, (0, CANVAS_H - glow_h))

    # ---- 中性地面光斑：射灯打在舞台地面上 ----
    spot = Image.new("L", (CANVAS_W, CANVAS_H), 0)
    spot_draw = ImageDraw.Draw(spot)
    spot_draw.ellipse(
        (
            round(CANVAS_W * 0.2),
            round(CANVAS_H * 0.78),
            round(CANVAS_W * 0.8),
            round(CANVAS_H * 1.3),
        ),
        fill=round(255 * 0.09),
    )
    spot = spot.filter(ImageFilter.GaussianBlur(50))
    white = Image.new("RGB", canvas.size, "white")
    canvas.paste(white, (0, 0), spot)

    # ---- 海报排：圆角 + 白描边 + 落影 + 倒影 ----
    count = min(len(poster_paths), MAX_POSTERS)
    poster_w = round(CANVAS_W * POSTER_W_RATIO)
    poster_h = round(poster_w * 3 / 2)
    gap = round(CANVAS_W * POSTER_GAP_RATIO)
    row_w = count * poster_w + (count - 1) * gap
    x = (CANVAS_W - row_w) // 2
    y = round(CANVAS_H * POSTER_TOP_RATIO)
    radius = 6

    rounded_mask = Image.new("L", (poster_w, poster_h), 0)
    ImageDraw.Draw(rounded_mask).rounded_rectangle(
        (0, 0, poster_w - 1, poster_h - 1), radius=radius, fill=255
    )

    canvas_rgba = canvas.convert("RGBA")
    for i in range(count):
        poster = load_poster(poster_paths[i], poster_w)
        px = x + i * (poster_w + gap)

        # 落影：黑色圆角矩形下移 6px、重模糊
        shadow = Image.new("RGBA", canvas_rgba.size, (0, 0, 0, 0))
        shadow_tile = Image.new("RGBA", (poster_w, poster_h), (0, 0, 0, 128))
        shadow.paste(shadow_tile, (px, y + 8), rounded_mask)
        shadow = shadow.filter(ImageFilter.GaussianBlur(10))
        canvas_rgba = Image.alpha_composite(canvas_rgba, shadow)

        # 海报本体（圆角）+ 1px 白描边
        tile = Image.new("RGBA", canvas_rgba.size, (0, 0, 0, 0))
        tile.paste(poster, (px, y), rounded_mask)
        ImageDraw.Draw(tile).rounded_rectangle(
            (px, y, px + poster_w - 1, y + poster_h - 1),
            radius=radius,
            outline=(255, 255, 255, 51),
            width=1,
        )
        canvas_rgba = Image.alpha_composite(canvas_rgba, tile)

        # 倒影：翻转副本贴底边，轻模糊，向下快速渐隐（近处最实 0.4 → 26% 处消失）
        flipped = poster.transpose(Image.FLIP_TOP_BOTTOM).filter(
            ImageFilter.GaussianBlur(1)
        )
        refl_h = poster_h
        fade = Image.new("L", (poster_w, refl_h), 0)
        fade_draw = ImageDraw.Draw(fade)
        fade_span = round(refl_h * 0.26)
        for ry in range(fade_span):
            alpha = round(255 * 0.4 * (1 - ry / fade_span))
            fade_draw.line([(0, ry), (poster_w, ry)], fill=alpha)
        refl_mask = Image.new("L", (poster_w, refl_h), 0)
        refl_mask.paste(fade, (0, 0), rounded_mask)
        refl = Image.new("RGBA", canvas_rgba.size, (0, 0, 0, 0))
        refl.paste(flipped, (px, y + poster_h + 2), refl_mask)
        canvas_rgba = Image.alpha_composite(canvas_rgba, refl)

    canvas_rgba.convert("RGB").save(out, "JPEG", quality=88, optimize=True)
