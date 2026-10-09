"""站点数据包：把一组站点 YAML 打成插件分发（plugin-phase2b.md §6）。

适合「几个朋友共用一批自己适配的站点」：不用每个人往 ``data/site-configs/`` 里手抄 YAML，装上插件
即出现在 设置 → 站点 的可选列表里；卸下插件，这些站点随之消失（已保存的站点凭据不受影响）。

优先级：内置站点 < 数据包 < 用户目录 ``data/site-configs/``（同 site_id 后者覆盖前者）。
YAML 的写法与内置站点完全相同（见 ``src/movieclaw_tracker/sites/configs/_template.yaml``）；
``custom_class`` 只能引用内置站点类或插件注册的站点类，不再接受任意导入路径。

目录结构（整个目录复制到数据目录的 ``plugins/`` 下）::

    plugins/site_pack/__init__.py     ← 本文件
    plugins/site_pack/sites/*.yaml    ← 站点配置

开启方式（``data/plugins.yaml``）::

    - id: site-pack
      local: true
"""

from __future__ import annotations

from pathlib import Path

from movieclaw_api.plugins.keys import SITE_DATA_PACKS
from movieclaw_kernel import Context, plugin

SITES_DIR = Path(__file__).resolve().parent / "sites"


@plugin("site-pack", title="站点数据包（示例）")
async def site_pack(ctx: Context) -> None:
    count = len(list(SITES_DIR.glob("*.yaml")))
    if count == 0:
        raise RuntimeError(f"{SITES_DIR} 里没有站点 YAML")
    ctx.contribute(SITE_DATA_PACKS, "sites", SITES_DIR)
    ctx.logger.info("站点数据包已挂上：%d 个站点", count)
