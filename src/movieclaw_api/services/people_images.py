"""演职员头像的本地存储（docs/design/image-sizing.md §4.2 / P3）。

头像原先一律是 TMDB 图床地址，断网就空；现在随条目刮削下载到本地，详情页、影人页、
刷片、Jellyfin 人物图都优先读本地。

存储结构::

    data/metadata/people/
      original/                 ← 档位一层：换档位整层替换，旧层整体作孤儿清理
        kj/                     ← TMDB 文件名前两位分桶，单个目录的文件数可控
          kjz9dl25oi1stWmb7TVnBSBP51y.jpg

- **按 TMDB 头像路径命名**：TMDB 的图片路径就是内容身份（换图即换路径），同一个人在
  多少部片里出现都只存一份，也不需要数据库列——有没有下过看文件在不在；
- 人物换了新头像就按新路径下载，旧文件不再被引用（单个头像很小，不逐张清理）。

本模块只放路径与地址（接口层大量调用，保持轻量）；下载在 ``media_scrape`` 里，与条目
图片共用格式校验与落盘工具。
"""

from __future__ import annotations

import re
from pathlib import Path

from movieclaw_api.core.config import get_settings

# NFO 里吸收来的 TMDB 头像绝对地址：…/t/p/<档位>/<文件名>
_TMDB_IMAGE_URL = re.compile(r"/t/p/[a-z0-9]+(/[A-Za-z0-9_\-]+\.(?:jpg|jpeg|png|webp))$")
_URL_PREFIX = "/images/people/"
_TIERS = ("original", "h632", "w185", "w45")


def people_root() -> Path:
    """头像根目录（Settings 字段，部署可改；与 data/ 其他目录一同持久化）。"""
    return Path(get_settings().people_images_dir)


def profile_path_of(url_or_path: str | None) -> str | None:
    """TMDB 头像路径（``/abc.jpg``）；NFO 带来的 TMDB 绝对地址也换算成路径，其他来源返回 None。"""
    if not url_or_path:
        return None
    if url_or_path.startswith("/") and "/" not in url_or_path[1:]:
        return url_or_path
    match = _TMDB_IMAGE_URL.search(url_or_path)
    return match.group(1) if match else None


def avatar_rel(profile_path: str, tier: str) -> str:
    """头像在根目录下的相对路径：``<档位>/<前两位>/<文件名>``。"""
    name = profile_path.lstrip("/")
    return f"{tier}/{name[:2]}/{name}"


def avatar_file(profile_path: str, tier: str) -> Path:
    return people_root() / avatar_rel(profile_path, tier)


def avatar_url(profile_path: str | None, *, fallback: str | None = None) -> str | None:
    """接口给客户端的头像地址：本地有就给本地（断网可用），否则给图床地址兜底。

    ``fallback``：没有 TMDB 头像路径时的其它地址（如 NFO 里非 TMDB 来源的头像），原样返回。
    """
    from movieclaw_api.services.network_egress import effective_tmdb_image_base_url
    from movieclaw_api.services.scrape_config import effective_profile_size

    path = profile_path_of(profile_path)
    if path is None:
        return fallback
    tier = effective_profile_size()
    # 先找全局档位；库级覆盖可能让这个人的头像落在别的档位层
    for candidate in (tier, *(t for t in _TIERS if t != tier)):
        if avatar_file(path, candidate).is_file():
            return _URL_PREFIX + avatar_rel(path, candidate)
    return f"{effective_tmdb_image_base_url().rstrip('/')}/{tier}{path}"


def resolve_avatar_path(rel: str) -> Path | None:
    """``/images/people/<rel>`` → 磁盘文件；越出根目录（目录穿越）或不存在返回 None。"""
    root = people_root().resolve()
    try:
        target = (root / rel).resolve()
    except (OSError, ValueError):
        return None
    if root not in target.parents or not target.is_file():
        return None
    return target
