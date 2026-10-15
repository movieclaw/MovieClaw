"""OpenList / alist 直链：strm 指向网盘挂载里的文件时，让播放器直接从网盘取。

设计见 docs/design/strm-playback.md §10。场景：Symedia、CloudDrive2 一类工具生成的 strm 里写的是
挂载路径（``/cd2/CloudDrive/115/电影/a.mkv``），默认由服务器读挂载再推给播放器，视频流量经过
服务器两遍。同一个网盘也挂在 OpenList（alist）里时，本插件按路径规则把挂载路径换成
OpenList 里的路径，向 OpenList 要这个文件的签名，交出 ``/d/<路径>?sign=…``——
OpenList 自己的 302 地址，115 一类存储会跳到网盘 CDN。

OpenList 在内网也没关系：系统会带着播放器的 User-Agent 替它跟跳转，落到网盘 CDN 再交给播放器
（115 直链与 UA 绑定，这样拿到的才是播放器能用的）。跟跳转落不到外网（OpenList 开了本地代理、
自己出字节）、OpenList 连不上、路径不在规则里，系统都照旧由服务器出字节，播放不受影响。

用到的扩展点：决策钩子 ``playback.strm.direct-link``（只读查询，不改任何东西）。

开启方式（``data/plugins.yaml``）::

    - id: openlist-direct-link
      local: true
      config:
        base_url: http://192.168.1.10:5244
        token: <OpenList 设置 → 其他 → 令牌；访客能读的存储可以留空>
        rules:
          - { mount: /cd2/CloudDrive/115, openlist: /115 }
"""

from __future__ import annotations

import os
from urllib.parse import quote

import httpx
from pydantic import BaseModel, Field, SecretStr

from movieclaw_api.hooks import STRM_DIRECT_LINK, DirectLink, MountedFile
from movieclaw_kernel import Context, plugin
from movieclaw_sdk import net


class Rule(BaseModel):
    mount: str = Field(
        description="服务器上的挂载路径前缀（与 strm 里写的一致），如 /cd2/CloudDrive/115"
    )
    openlist: str = Field(description="同一个目录在 OpenList 里的路径，如 /115")


class Config(BaseModel):
    base_url: str = Field(description="OpenList 地址，如 http://192.168.1.10:5244")
    token: SecretStr = Field(default=SecretStr(""), description="OpenList 令牌（设置 → 其他）")
    rules: list[Rule] = Field(default_factory=list, description="挂载路径 → OpenList 路径")
    ttl_s: int = Field(
        default=300, ge=0, le=3600, description="同一文件同一播放器复用直链多久（秒）"
    )


def openlist_path(path: str, rules: list[Rule]) -> str | None:
    """挂载路径 → OpenList 里的路径（最长前缀优先，按整段目录匹配）；不在任何规则里返回 None。

    系统给的是展开软链后的真实路径，规则按用户写的挂载路径配：两种写法都认。
    """
    best: tuple[int, str] | None = None
    for rule in rules:
        for mount in {rule.mount.rstrip("/"), os.path.realpath(rule.mount)}:
            if (path == mount or path.startswith(mount + "/")) and (
                best is None or len(mount) > best[0]
            ):
                best = (len(mount), rule.openlist.rstrip("/") + path[len(mount) :])
    return best[1] if best else None


@plugin("openlist-direct-link", title="OpenList 直链（示例）", config=Config)
async def openlist_direct_link(ctx: Context[Config]) -> None:
    config = ctx.config
    base = config.base_url.rstrip("/")
    client = httpx.AsyncClient(transport=net.http_transport("openlist-direct-link"), timeout=1.5)
    ctx.effect(client.aclose, label="openlist-client")

    async def direct_link(file: MountedFile) -> DirectLink | None:
        remote = openlist_path(file.path, config.rules)
        if remote is None:
            return None  # 不是本插件管的挂载
        try:
            response = await client.post(
                f"{base}/api/fs/get",
                json={"path": remote, "password": ""},
                headers={"Authorization": config.token.get_secret_value()},
            )
            body = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            ctx.logger.warning("OpenList 连不上，照旧由服务器出字节：%s", exc)
            return None
        if body.get("code") != 200:
            ctx.logger.warning("OpenList 找不到 %s：%s", remote, body.get("message"))
            return None
        sign = (body.get("data") or {}).get("sign") or ""
        url = f"{base}/d{quote(remote)}" + (f"?sign={sign}" if sign else "")
        return DirectLink(url=url, ttl_s=config.ttl_s)

    ctx.on(STRM_DIRECT_LINK, direct_link)
