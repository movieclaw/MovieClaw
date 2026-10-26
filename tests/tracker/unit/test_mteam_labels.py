"""M-Team 站点标记（labelsNew）解析单元测试。

站点把杜比视界与 HDR10 兼容格式分开标（``DoVi`` / ``hdr10`` / ``hdr10+``），是判定
杜比视界 Profile 5 的一条证据（docs/design/avoid-dv-p5.md）。列表与搜索接口都带，
不需要额外请求。载荷按 2026-10-23 对真实详情接口的响应整理。
"""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest

from movieclaw_tracker import load_all_sites
from movieclaw_tracker.models import SearchQuery, TorrentCategory
from movieclaw_tracker.registry import get_site_config
from movieclaw_tracker.sites.custom.mteam import MTeamSite


@pytest.fixture(scope="module", autouse=True)
def _load_configs() -> None:
    load_all_sites()


def _payload(**overrides: Any) -> dict[str, Any]:
    base = {
        "id": "1251530",
        "name": "Mayday 2026 2160p ATVP WEB-DL DDP 5.1 Atmos DV H.265-FLUX",
        "smallDescr": "求救信号 / 求救暗号 | 类型: 动作 / 冒险",
        "category": "419",
        "size": "21474836480",
        "createdDate": "2026-10-20 12:00:00",
        "labels": "4",
        "labelsNew": ["中字", "4k", "DoVi"],
        "status": {"discount": "NORMAL", "seeders": "50", "leechers": "2", "timesCompleted": "9"},
    }
    base.update(overrides)
    return base


def _site(payload: dict[str, Any]) -> MTeamSite:
    config = get_site_config("mteam")
    response = MagicMock()
    response.json.return_value = {
        "code": "0",
        "message": "SUCCESS",
        "data": {"data": [payload], "totalPages": 1},
    }
    client = MagicMock()
    client.post = AsyncMock(return_value=response)
    return MTeamSite(
        site_id=config.site_id,
        base_url=config.base_url,
        web_base_url=config.web_base_url,
        category_map=config.category_map,
        client=client,
        auth_manager=MagicMock(),
    )


async def _only_item(payload: dict[str, Any]):
    result = await _site(payload).search(
        SearchQuery(keyword="Mayday", categories=[TorrentCategory.MOVIE])
    )
    assert len(result.items) == 1
    return result.items[0]


async def test_labels_new_is_kept_in_site_order() -> None:
    item = await _only_item(_payload())
    assert item.labels == ["中字", "4k", "DoVi"]


@pytest.mark.parametrize("raw", [None, [], ["", None]])
async def test_missing_or_empty_labels_are_an_empty_list(raw) -> None:
    item = await _only_item(_payload(labelsNew=raw))
    assert item.labels == []


async def test_labels_stay_out_of_the_api_output() -> None:
    """标记只给内部管线用：搜索结果等响应模型的输出契约不因此多出字段。"""
    item = await _only_item(_payload())
    assert "labels" not in item.model_dump()
