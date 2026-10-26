"""网络与代理配置域（「设置 → 网络」页的数据模型）。

与 ``movieclaw_net`` 的关系：本模块只负责**声明与持久化**用户的网络配置；
把配置灌进出口层使其生效的运行时逻辑在 ``services/network_egress.py``。

字段设计对应设置页的三块内容：
1. 代理模式与地址（off / env / manual + http/socks5 地址）；
2. 每服务走代理开关（``proxy_services``，含 ``site:<id>`` 形式的 PT 站条目）；
3. 镜像地址覆盖（TMDB 接口/图床、豆瓣接口；空 = 用环境变量或内置默认值）。
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from movieclaw_api.settings.base import SettingSchema, register_setting

# 服务标签目录：设置页开关列表的固定部分（PT 站条目按已配置站点动态生成）。
# 名称与说明是消息键，按读者语言渲染；代码内一律用 id。
BUILTIN_EGRESS_SERVICES: list[dict[str, str]] = [
    {
        "id": "tmdb",
        "label_key": "settings.network.services.tmdbLabel",
        "description_key": "settings.network.services.tmdbHint",
    },
    {
        "id": "image",
        "label_key": "settings.network.services.imageLabel",
        "description_key": "settings.network.services.imageHint",
    },
    {
        "id": "fanart",
        "label_key": "settings.network.services.fanartLabel",
        "description_key": "settings.network.services.fanartHint",
    },
    {
        "id": "douban",
        "label_key": "settings.network.services.doubanLabel",
        "description_key": "settings.network.services.doubanHint",
    },
    {
        "id": "llm",
        "label_key": "settings.network.services.llmLabel",
        "description_key": "settings.network.services.llmHint",
    },
    # 默认不进 proxy_services。海外接口常常要代理，但由用户在「设置 → 网络」里自己打开。
    {
        "id": "web_search",
        "label_key": "settings.network.services.webSearchLabel",
        "description_key": "settings.network.services.webSearchHint",
    },
    {
        "id": "telegram",
        "label_key": "settings.network.services.telegramLabel",
        "description_key": "settings.network.services.telegramHint",
    },
    {
        "id": "discord",
        "label_key": "settings.network.services.discordLabel",
        "description_key": "settings.network.services.discordHint",
    },
    {
        "id": "feishu",
        "label_key": "settings.network.services.feishuLabel",
        "description_key": "settings.network.services.feishuHint",
    },
    {
        "id": "webhook",
        "label_key": "settings.network.services.webhookLabel",
        "description_key": "settings.network.services.webhookHint",
    },
    {
        "id": "movieclaw_cloud",
        "label_key": "settings.network.services.movieclawCloudLabel",
        "description_key": "settings.network.services.movieclawCloudHint",
    },
    {
        "id": "movieclaw_push",
        "label_key": "settings.network.services.movieclawPushLabel",
        "description_key": "settings.network.services.movieclawPushHint",
    },
    {
        "id": "pypi",
        "label_key": "settings.network.services.pypiLabel",
        "description_key": "settings.network.services.pypiHint",
    },
    {
        "id": "github",
        "label_key": "settings.network.services.githubLabel",
        "description_key": "settings.network.services.githubHint",
    },
]


@register_setting(
    namespace="network.egress",
    title="网络与代理",
    # 代理地址可能内嵌认证信息（http://user:pass@host:port），按敏感字段加密落库
    secret_fields=["proxy_url"],
)
class NetworkEgressSetting(SettingSchema):
    """统一网络出口配置。默认值 = 跟随环境变量，TMDB、图片回源与 GitHub
    更新走代理。

    这样 Docker 部署者只要 ``-e HTTPS_PROXY=...`` 就能解决最常见的
    「TMDB / GitHub 被墙」问题，而 PT 站/豆瓣保持直连（国内直连通常更快，
    且部分 PT 站风控在意出口 IP）。
    """

    proxy_mode: Literal["off", "env", "manual"] = Field(
        default="env",
        description="代理模式：off 全部直连；env 代理地址取自环境变量；manual 手动填写",
    )
    proxy_url: str = Field(
        default="",
        description="手动模式的代理地址，支持 http:// 与 socks5://（如 socks5://192.168.1.2:7891）",
    )
    proxy_services: list[str] = Field(
        default_factory=lambda: ["tmdb", "image", "fanart", "github"],
        description="走代理的服务标签列表；PT 站用 site:<站点id> 形式按站独立控制",
    )
    tmdb_api_base_url: str = Field(
        default="", description="TMDB 接口镜像地址覆盖；空 = 环境变量或官方默认"
    )
    tmdb_image_base_url: str = Field(
        default="", description="TMDB 图床镜像地址覆盖；空 = 环境变量或官方默认"
    )
    douban_api_base_url: str = Field(
        default="", description="豆瓣接口反代地址覆盖；空 = 环境变量或内置默认"
    )
    pypi_index_url: str = Field(
        default="",
        description="插件依赖的包索引地址（PEP 503 simple）；空 = PyPI 官方",
    )
