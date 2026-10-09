"""OpenAPI 指纹跨 app 缓存的回归测试。"""

from __future__ import annotations

from fastapi import FastAPI

import movieclaw_api.spec_state as spec_state
from movieclaw_api.app import create_app


def test_equivalent_apps_share_spec_hash_generation(monkeypatch) -> None:
    """create_app 的同构实例只算一次指纹，结果仍写回各自 app.state。"""
    spec_state._shared_spec_hashes.clear()
    monkeypatch.setattr(spec_state, "_baseline_hash", None)
    calls = 0
    original = spec_state.spec_hash

    def counted(spec):  # type: ignore[no-untyped-def]
        nonlocal calls
        calls += 1
        return original(spec)

    monkeypatch.setattr(spec_state, "spec_hash", counted)
    first = create_app()
    second = create_app()

    assert spec_state.get_spec_hash(first) == spec_state.get_spec_hash(second)
    assert calls == 1
    assert first.state.spec_hash == second.state.spec_hash


def test_different_route_tables_do_not_share_spec_hash(monkeypatch) -> None:
    """动态追加路由会改变签名，不能复用另一份 app 的指纹。"""
    spec_state._shared_spec_hashes.clear()
    calls = 0
    original = spec_state.spec_hash

    def counted(spec):  # type: ignore[no-untyped-def]
        nonlocal calls
        calls += 1
        return original(spec)

    def shared_endpoint() -> dict[str, bool]:
        return {"ok": True}

    monkeypatch.setattr(spec_state, "spec_hash", counted)
    first = FastAPI()
    first.add_api_route("/first", shared_endpoint)
    second = FastAPI()
    second.add_api_route("/second", shared_endpoint)

    assert spec_state.get_spec_hash(first) != spec_state.get_spec_hash(second)
    assert calls == 2


def test_product_app_takes_the_hash_from_the_build_baseline(monkeypatch, tmp_path) -> None:
    """产品应用有基线文件时直接取基线指纹，不在请求路径上现场生成整份 spec。"""
    import json

    from movieclaw_api.export_openapi import build_spec, spec_hash
    from movieclaw_api.services import spec_catalog

    baseline = tmp_path / "spec.json"
    baseline.write_text(json.dumps(build_spec()), encoding="utf-8")
    monkeypatch.setattr(spec_catalog, "_SPEC_PATH", baseline)
    monkeypatch.setattr(spec_state, "_baseline_hash", None)
    app = create_app()

    def forbidden(*args, **kwargs):  # type: ignore[no-untyped-def]
        raise AssertionError("有基线时不该现场生成 OpenAPI")

    monkeypatch.setattr(app, "openapi", forbidden)
    assert spec_state.get_spec_hash(app) == spec_hash(json.loads(baseline.read_text()))


def test_without_baseline_the_hash_is_computed_live(monkeypatch, tmp_path) -> None:
    from movieclaw_api.export_openapi import spec_hash
    from movieclaw_api.services import spec_catalog

    monkeypatch.setattr(spec_catalog, "_SPEC_PATH", tmp_path / "missing.json")
    monkeypatch.setattr(spec_state, "_baseline_hash", None)
    spec_state._shared_spec_hashes.clear()
    app = create_app()
    assert spec_state.get_spec_hash(app) == spec_hash(app.openapi())
