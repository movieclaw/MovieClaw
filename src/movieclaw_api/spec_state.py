"""spec 内容指纹的进程内缓存。

指纹用途（docs/design/cli.md §2.1）：CLI 比对「内置基线 spec 的 hash」与
「服务器返回的 hash」即可零成本发现版本偏斜。指纹随 /health 响应与所有
/api/v1 响应头（X-Movieclaw-Spec-Hash）下发；算法与 export_openapi.spec_hash
完全一致——两端必须同一算法，否则偏斜检测失效。
"""

from __future__ import annotations

import logging
import threading
import time
import weakref
from collections import OrderedDict
from typing import Any

from fastapi import FastAPI
from fastapi.routing import APIRoute, iter_route_contexts

from movieclaw_api.export_openapi import spec_hash

logger = logging.getLogger("movieclaw_api.spec_state")

SPEC_HASH_HEADER = "X-Movieclaw-Spec-Hash"

# create_app() 在测试中会为每个用例构造新 FastAPI 实例，但这些实例挂载的业务
# 路由完全相同。FastAPI 只把 OpenAPI 缓存在 app.openapi_schema 上，原先再叠加的
# app.state 缓存仍无法跨实例复用，导致 400KB 级 schema 被重复生成数百次。
#
# 这里按「会影响 OpenAPI 的应用元数据 + 路由声明」做一个小型进程级缓存：生产环境
# 通常只有一个 app；测试里的同构 app 命中同一项；临时追加路由的测试则因签名不同
# 独立计算。缓存有界，避免动态创建大量 app 时长期持有端点函数。
_SHARED_CACHE_SIZE = 8
_shared_spec_hashes: OrderedDict[tuple[Any, ...], str] = OrderedDict()
_shared_spec_hashes_lock = threading.Lock()


def _stable_value(value: Any) -> Any:
    """把路由元数据变成可哈希值；常见类/函数保留身份，容器退回 repr。"""
    try:
        hash(value)
    except TypeError:
        return repr(value)
    return value


def _route_signature(app: FastAPI) -> tuple[Any, ...]:
    """提取足以区分 OpenAPI 声明的轻量签名，不触发 schema 生成。

    FastAPI 0.142 起 ``app.routes`` 里只剩「被包含的路由器」，要经 ``iter_route_contexts``
    展开成实际生效的路由（前缀、路由器级依赖都已合并），否则签名里一条路由都没有。
    """
    routes = tuple(
        (
            route.path_format,
            tuple(sorted(route.methods or ())),
            route.endpoint,
            route.name,
            route.operation_id,
            route.include_in_schema,
            route.status_code,
            route.summary,
            route.description,
            route.deprecated,
            tuple(route.tags or ()),
            _stable_value(route.response_model),
            _stable_value(route.response_class),
            repr(route.responses),
            repr(route.openapi_extra),
            tuple(_stable_value(item.dependency) for item in route.dependencies),
        )
        for route in iter_route_contexts(app.routes)
        if isinstance(route.original_route, APIRoute)
    )
    return (
        app.title,
        app.summary,
        app.description,
        app.version,
        app.openapi_version,
        repr(app.servers),
        repr(app.openapi_tags),
        app.separate_input_output_schemas,
        routes,
    )


_baseline_hash: str | None = None
#: 路由与基线 spec 同源的应用（create_app 产出的产品应用）；测试里临时拼的应用不在其中
_baseline_apps: weakref.WeakSet[FastAPI] = weakref.WeakSet()


def mark_baseline_app(app: FastAPI) -> None:
    _baseline_apps.add(app)


ROUTES_CHANGED_DEBOUNCE = 1.0


def routes_changed(app: FastAPI) -> threading.Thread:
    """应用的路由在运行中变了（插件挂 / 摘路由）：不再认基线，后台线程重算指纹。

    现算整份 spec 在 NAS 上要好几秒；算好之前各响应沿用旧指纹（CLI 至多晚一次发现偏斜），
    不在事件循环里同步卡住请求。连续变化只认最后一次（防抖 1 秒）。返回线程，测试可以等它算完。
    """
    from fastapi.openapi.utils import get_openapi

    # 先定下「旧指纹」（基线应用只是读文件），保证线程算完之前请求不会走现场生成
    get_spec_hash(app)
    _baseline_apps.discard(app)
    generation = getattr(app.state, "spec_generation", 0) + 1
    app.state.spec_generation = generation
    # 在事件循环上先把生效路由快照下来（很快），线程只基于快照生成：请求处理会按路由版本
    # 重建生效路由对象，线程里两遍遍历若拿到不同的对象，字段映射对不上（KeyError）
    routes = list(iter_route_contexts(app.routes))
    webhooks = list(iter_route_contexts(app.webhooks.routes))
    routes_version = app.router._get_routes_version()

    def compute() -> None:
        # 防抖：启动时连挂几个插件的路由只算最后一次
        time.sleep(ROUTES_CHANGED_DEBOUNCE)
        if getattr(app.state, "spec_generation", None) != generation:
            return
        try:
            # 参数与 FastAPI.openapi() 一致，结果与现场生成逐字节相同
            spec = get_openapi(
                title=app.title,
                version=app.version,
                openapi_version=app.openapi_version,
                summary=app.summary,
                description=app.description,
                terms_of_service=app.terms_of_service,
                contact=app.contact,
                license_info=app.license_info,
                routes=routes,
                webhooks=webhooks,
                tags=app.openapi_tags,
                servers=app.servers,
                separate_input_output_schemas=app.separate_input_output_schemas,
                external_docs=app.openapi_external_docs,
            )
            value: str | None = spec_hash(spec)
        except Exception:
            # 路由恰好在生成过程中又变了等：交给下一次变化或请求现算
            logger.warning("重算 spec 指纹失败，改由下次请求现场计算", exc_info=True)
            value = None
        if getattr(app.state, "spec_generation", None) != generation:
            return
        if value is not None:
            app.state.spec_hash = value
            # 顺手填上 FastAPI 自己的 OpenAPI 缓存（按快照时的路由版本）：CLI 发现指纹变了会来拉
            # /spec，不必再在事件循环里现场生成一遍；路由若已再变，版本对不上，FastAPI 照常重算
            app.openapi_schema = spec
            app._openapi_routes_version = routes_version
        elif getattr(app.state, "spec_hash", None) is not None:
            del app.state.spec_hash

    thread = threading.Thread(target=compute, name="spec-hash", daemon=True)
    thread.start()
    return thread


def _hash_from_baseline() -> str | None:
    """构建期导出的基线 spec 的指纹；没有基线文件（源码直接运行）返回 None。

    基线由同一份代码导出（正式发布与开发版部署的产物里都有，见 spec_catalog），指纹与现场
    ``app.openapi()`` 算出的完全一致；读文件约几十毫秒，而现场生成整份 spec 要好几秒，且在
    事件循环里同步执行——NAS 上重启后的第一个请求（常常就是健康检查）会被它卡住 7 秒多。
    """
    global _baseline_hash
    if _baseline_hash is None:
        import json

        from movieclaw_api.services.spec_catalog import _SPEC_PATH

        try:
            text = _SPEC_PATH.read_text(encoding="utf-8")
        except OSError:
            return None
        try:
            _baseline_hash = spec_hash(json.loads(text))
        except ValueError:
            return None
    return _baseline_hash


def get_spec_hash(app: FastAPI) -> str:
    """取当前 app 的 spec 指纹，并在同构 app 之间复用计算结果。"""
    cached = getattr(app.state, "spec_hash", None)
    if cached is not None:
        return cached
    if app in _baseline_apps:
        baseline = _hash_from_baseline()
        if baseline is not None:
            app.state.spec_hash = baseline
            return baseline

    signature = _route_signature(app)
    # 首次生成约需数百毫秒。锁覆盖计算过程，避免并发启动多个同构 app 时重复
    # 做同一份 CPU 密集工作；后续请求先命中 app.state，不会再竞争此锁。
    with _shared_spec_hashes_lock:
        cached = _shared_spec_hashes.get(signature)
        if cached is None:
            cached = spec_hash(app.openapi())
            _shared_spec_hashes[signature] = cached
            if len(_shared_spec_hashes) > _SHARED_CACHE_SIZE:
                _shared_spec_hashes.popitem(last=False)
        else:
            _shared_spec_hashes.move_to_end(signature)

    app.state.spec_hash = cached
    return cached
