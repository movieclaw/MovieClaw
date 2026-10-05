"""刮削与整理设置接口（「设置 → 刮削与整理」页的后端）。

- GET  /scrape/config —— 当前配置 + 各"跟随环境变量"字段的生效默认值；
- PUT  /scrape/config —— **只更新请求体里出现的字段**，其余保持原样，
  保存后立即生效（快照热更新；对存量条目生效需整库刷新，前端保存后
  给出引导）。

为什么 PUT 是"局部更新"而不是整体替换：这是一份**十几个字段的单例配置**，
Web 端总是整体提交（行为无差别），但 CLI 与 Agent 天然是"只改一项"的用法
——``mclaw scrape set --poster-mode language`` 如果把没提到的字段一并按
默认值写回去，用户精心配好的语言优先级和命名模板会被一条命令悄悄抹掉。
想把某项恢复默认，显式传空值（``""`` / ``[]``）即可。
- GET  /scrape/language-options —— 完整语种表（TMDB configuration/languages，
  进程内缓存；TMDB 不可用时回落内置常用表）；
- GET  /scrape/country-options —— 完整地区表（configuration/countries，同上）。
- GET  /scrape/fanart —— Fanart.tv 凭据状态（配没配、是否失效、末四位，不含明文）；
- PUT  /scrape/fanart —— 验证并保存 Fanart.tv API Key（验证不过不保存）。

配置的运行时装配见 ``services/scrape_config.py``。
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import BadRequestException, UpstreamUnreachableException
from movieclaw_api.schemas.response import ApiResponse, ok
from movieclaw_api.services.media_discover import get_tmdb_client, reset_media_service
from movieclaw_api.services.scrape_config import (
    current_scrape_setting,
    effective_asset_sizes,
    effective_cert_countries,
    effective_image_quality,
    effective_languages,
    effective_profile_size,
    save_scrape_setting,
)
from movieclaw_api.settings import MetadataScrapeSetting
from movieclaw_db.engine import get_session

logger = logging.getLogger("movieclaw_api.scrape_settings")

router = APIRouter(prefix="/scrape", tags=["scrape"])


class ScrapeEffectiveView(BaseModel):
    """ "跟随环境变量"字段当前的生效值（前端展示"跟随中：xxx"用）。"""

    language_priority: list[str]
    cert_country_priority: list[str]
    poster_size: str
    backdrop_size: str
    still_size: str
    profile_size: str = Field(description="演职员头像的生效档位")
    image_quality: str = Field(
        description="界面该选中的本地图片画质：original / standard / compact / custom"
        "（没选过时按四个档位反推，等于某个预设就是它，否则 custom）"
    )


class ScrapeConfigView(BaseModel):
    setting: MetadataScrapeSetting
    effective: ScrapeEffectiveView


class LanguageOption(BaseModel):
    code: str = Field(description="ISO 639-1 语言码（zh / en / ja …）")
    name: str = Field(description="该语言的本族名（TMDB name，缺失回落英文名）")
    english_name: str = ""


class CountryOption(BaseModel):
    code: str = Field(description="ISO 3166-1 地区码（CN / US …）")
    name: str = Field(description="地区中文名（TMDB native_name，缺失回落英文名）")


def _config_view() -> ScrapeConfigView:
    return ScrapeConfigView(
        setting=current_scrape_setting(),
        effective=ScrapeEffectiveView(
            language_priority=effective_languages(),
            cert_country_priority=effective_cert_countries(),
            poster_size=effective_asset_sizes()[0],
            backdrop_size=effective_asset_sizes()[1],
            still_size=effective_asset_sizes()[2],
            profile_size=effective_profile_size(),
            image_quality=effective_image_quality(),
        ),
    )


@router.get(
    "/config",
    response_model=ApiResponse[ScrapeConfigView],
    summary="读取刮削与整理配置",
    operation_id="scrape.show",
)
async def get_scrape_config() -> ApiResponse[ScrapeConfigView]:
    """返回 ``setting``（用户配置，留空表示跟随环境变量）与 ``effective``
    （留空字段当前实际生效的值）。改配置前先读一遍，避免把留空当成没配。"""
    return ok(_config_view())


@router.put(
    "/config",
    response_model=ApiResponse[ScrapeConfigView],
    summary="修改刮削与整理配置：只更新给出的字段，没给的保持原样（立即生效）",
    operation_id="scrape.set",
)
async def save_scrape_config(payload: MetadataScrapeSetting) -> ApiResponse[ScrapeConfigView]:
    """只改你给出的那几项，没给的保持原样；想把某项恢复默认就显式传空值（"" 或 []）。

    优先级类字段是有序列表，越靠前越优先。language_priority 的首位就是向
    TMDB 请求的语言，后面的用于该语言缺文本时逐级回落。图片语言里三个特殊
    取值：meta = 跟随元数据主语言，orig = 影片发行时的原始语言，null = 无
    文字的纯画面版本。

    例：只把海报改成按语言挑，其余配置不动——
    mclaw scrape set --poster-mode language

    改动只影响之后的刮削与整理，不会追改存量内容。改了语言、选图或图片档位，
    用 library metadata refresh 重刷存量条目；改了命名模板，用 library
    organize-files 把存量文件改名归位（先 --dry-run 看计划，确认后加 --yes）。
    模板可以反复改、反复整理，条目目录改名时海报和 NFO 会一起搬走，不留空目录。
    """
    # model_fields_set 区分"显式传了默认值"和"根本没传"：前者按用户意图写入
    # （这正是"恢复默认"的表达方式），后者原样保留
    merged = MetadataScrapeSetting.model_validate(
        {**current_scrape_setting().model_dump(), **payload.model_dump(exclude_unset=True)}
    )
    await save_scrape_setting(merged)
    # 主语言也喂给发现页服务（构造期绑定），重建单例让新语言下次请求生效
    reset_media_service()
    return ok(_config_view())


class ImageStorageCountsView(BaseModel):
    posters: int = Field(description="条目海报 + 季海报张数")
    backdrops: int
    logos: int
    stills: int = Field(description="有文件的剧集的分集剧照张数")
    people: int = Field(description="演职员头像张数（按人去重）")


class ImageStorageEstimateView(BaseModel):
    counts: ImageStorageCountsView
    presets: dict[str, int] = Field(
        description="各画质档的估算字节数：original / standard / compact"
    )
    current_quality: str = Field(description="当前生效的画质档（自定义为 custom）")
    current_bytes: int = Field(description="按当前生效档位的估算字节数")


@router.get(
    "/storage-estimate",
    response_model=ApiResponse[ImageStorageEstimateView],
    summary="本地图片画质的磁盘估算（按当前媒体库的图片张数）",
    operation_id="scrape.storage-estimate",
    openapi_extra={"x-cli-hidden": True},
)
async def get_image_storage_estimate(
    session: AsyncSession = Depends(get_session),
) -> ApiResponse[ImageStorageEstimateView]:
    """设置页「本地图片画质」旁的「约 X GB」：张数 × 各档位单张均值，只是量级参考。"""
    from movieclaw_api.services.image_estimate import estimate_image_storage

    return ok(ImageStorageEstimateView.model_validate(await estimate_image_storage(session)))


# ---------------------------------------------------------------------------
# Fanart.tv 凭据（docs/design/image-sources.md §3）
# ---------------------------------------------------------------------------


class FanartStatusView(BaseModel):
    configured: bool = Field(description="是否已保存过 Fanart.tv API Key")
    key_invalid: bool = Field(
        description="已保存的 Key 被 Fanart.tv 拒绝过（刮削时遇到 401），需要重新填写"
    )
    key_hint: str = Field(description="Key 的末四位（展示「••••abcd」用）；没配置为空串")


class FanartKeyPayload(BaseModel):
    api_key: str = Field(min_length=1, max_length=200, description="Fanart.tv API Key")


@router.get(
    "/fanart",
    response_model=ApiResponse[FanartStatusView],
    summary="Fanart.tv 图片来源的 Key 状态（不含明文）",
    operation_id="scrape.fanart.show",
)
async def get_fanart_status() -> ApiResponse[FanartStatusView]:
    """Fanart.tv 需要使用者自己的 API Key（fanart.tv 免费注册即可获得），本项目
    不内置。这里只回配没配、是否已失效与末四位。"""
    from movieclaw_api.services.fanart import fanart_status

    return ok(FanartStatusView(**fanart_status()))


@router.put(
    "/fanart",
    response_model=ApiResponse[FanartStatusView],
    summary="验证并保存 Fanart.tv API Key（全站共用；验证不过不保存）",
    operation_id="scrape.fanart.set-key",
)
async def save_fanart_key(payload: FanartKeyPayload) -> ApiResponse[FanartStatusView]:
    """先用这把 Key 向 Fanart.tv 发一次真实请求，通过了才保存（原有 Key 不受
    失败的尝试影响）。保存后自动选图是否使用 Fanart 由刮削配置里的
    fanart_enabled 决定：mclaw scrape set --fanart-enabled true"""
    from movieclaw_api.services.fanart import fanart_status, verify_and_save_key
    from movieclaw_media.fanart import FanartAuthError, FanartError, FanartNetworkError

    try:
        await verify_and_save_key(payload.api_key)
    except FanartAuthError as exc:
        raise BadRequestException(
            "Key 无效：Fanart.tv 返回「401 未授权」。请检查是否复制完整，"
            "或到 fanart.tv 个人页重新生成"
        ) from exc
    except FanartNetworkError as exc:
        raise UpstreamUnreachableException(
            str(exc),
            service="fanart",
            hint="到「设置 → 网络与代理」为「Fanart.tv」开启代理后再试",
        ) from exc
    except FanartError as exc:
        raise BadRequestException(str(exc)) from exc
    return ok(FanartStatusView(**fanart_status()), message="Fanart.tv API Key 已验证并保存")


# ---------------------------------------------------------------------------
# 完整语种/地区表：TMDB configuration 接口 + 进程内缓存 + 内置回落
# ---------------------------------------------------------------------------

# 内置常用表：TMDB 不可用（未配 Key / 断网）时设置页仍能工作的最小集合
_BUILTIN_LANGUAGES = [
    {"code": "zh", "name": "中文", "english_name": "Chinese"},
    {"code": "en", "name": "English", "english_name": "English"},
    {"code": "ja", "name": "日本語", "english_name": "Japanese"},
    {"code": "ko", "name": "한국어", "english_name": "Korean"},
    {"code": "fr", "name": "Français", "english_name": "French"},
    {"code": "de", "name": "Deutsch", "english_name": "German"},
    {"code": "es", "name": "Español", "english_name": "Spanish"},
    {"code": "it", "name": "Italiano", "english_name": "Italian"},
    {"code": "ru", "name": "Pусский", "english_name": "Russian"},
    {"code": "pt", "name": "Português", "english_name": "Portuguese"},
    {"code": "th", "name": "ภาษาไทย", "english_name": "Thai"},
    {"code": "hi", "name": "हिन्दी", "english_name": "Hindi"},
]
_BUILTIN_COUNTRIES = [
    {"code": "CN", "name": "中国"},
    {"code": "US", "name": "美国"},
    {"code": "JP", "name": "日本"},
    {"code": "KR", "name": "韩国"},
    {"code": "GB", "name": "英国"},
    {"code": "FR", "name": "法国"},
    {"code": "DE", "name": "德国"},
    {"code": "HK", "name": "香港"},
    {"code": "TW", "name": "台湾"},
    {"code": "IN", "name": "印度"},
]

# 进程内缓存：语种/地区表几乎不变，进程生命周期内取一次即可
_language_cache: list[LanguageOption] | None = None
_country_cache: list[CountryOption] | None = None


@router.get(
    "/language-options",
    response_model=ApiResponse[list[LanguageOption]],
    summary="完整语种表（供「更多语言」搜索面板）",
    operation_id="scrape.languages",
)
async def list_language_options() -> ApiResponse[list[LanguageOption]]:
    global _language_cache
    if _language_cache is None:
        try:
            raw = await get_tmdb_client().get("configuration/languages", {})
            options = [
                LanguageOption(
                    code=entry["iso_639_1"],
                    name=(entry.get("name") or "").strip()
                    or (entry.get("english_name") or "").strip()
                    or entry["iso_639_1"],
                    english_name=(entry.get("english_name") or "").strip(),
                )
                for entry in raw
                if isinstance(entry, dict) and entry.get("iso_639_1")
            ]
            _language_cache = sorted(options, key=lambda o: o.code)
        except Exception as exc:  # noqa: BLE001 -- 全量表拉不到回落内置常用表
            logger.warning("TMDB 语种表拉取失败，回落内置常用表：%s", exc)
            return ok([LanguageOption(**entry) for entry in _BUILTIN_LANGUAGES])
    return ok(_language_cache)


@router.get(
    "/country-options",
    response_model=ApiResponse[list[CountryOption]],
    summary="完整地区表（供「更多地区」搜索面板）",
    operation_id="scrape.countries",
)
async def list_country_options() -> ApiResponse[list[CountryOption]]:
    global _country_cache
    if _country_cache is None:
        try:
            raw = await get_tmdb_client().get("configuration/countries", {"language": "zh-CN"})
            options = [
                CountryOption(
                    code=entry["iso_3166_1"],
                    name=(entry.get("native_name") or "").strip()
                    or (entry.get("english_name") or "").strip()
                    or entry["iso_3166_1"],
                )
                for entry in raw
                if isinstance(entry, dict) and entry.get("iso_3166_1")
            ]
            _country_cache = sorted(options, key=lambda o: o.code)
        except Exception as exc:  # noqa: BLE001 -- 同语种表：回落内置常用表
            logger.warning("TMDB 地区表拉取失败，回落内置常用表：%s", exc)
            return ok([CountryOption(**entry) for entry in _BUILTIN_COUNTRIES])
    return ok(_country_cache)
