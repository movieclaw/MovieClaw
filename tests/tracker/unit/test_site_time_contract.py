"""所有 PT 站点共用的时间契约回归测试。"""

from __future__ import annotations

from datetime import datetime
from unittest.mock import MagicMock

from parsel import Selector

from movieclaw_tracker import load_all_sites
from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite
from movieclaw_tracker.registry import get_site_config, list_sites
from movieclaw_tracker.selectors import NexusPHPSelectors
from movieclaw_tracker.sites.custom.mteam import MTeamSite


def _nexus_site(site_id: str) -> NexusPHPSite:
    config = get_site_config(site_id)
    assert isinstance(config.selectors, NexusPHPSelectors)
    return NexusPHPSite(
        selectors=config.selectors,
        category_map=config.category_map,
        site_id=config.site_id,
        base_url=config.base_url,
        client=MagicMock(),
        auth_manager=MagicMock(),
        timezone=config.timezone,
    )


def test_all_builtin_sites_default_to_shanghai_timezone() -> None:
    load_all_sites()

    # 25 个真实站点 + 公开演示站的离线演示资源站（sites/configs/demo.yaml）
    assert len(list_sites()) == 26
    assert {config.timezone for config in list_sites()} == {"Asia/Shanghai"}


def test_ttg_split_datetime_nodes_are_parsed_as_utc() -> None:
    load_all_sites()
    site = _nexus_site("ttg")
    row = Selector(
        text="<tr><td></td><td></td><td></td><td></td>"
        "<td>2026-08-13<br>17:03:05</td></tr>"
    )

    assert site._parse_upload_time(row) == datetime(2026, 8, 13, 9, 3, 5)


def test_nexus_promo_deadline_uses_same_site_timezone() -> None:
    load_all_sites()
    site = _nexus_site("chdbits")
    row = Selector(
        text='<tr><td class="embedded"><img class="pro_free">'
        '<span title="2026-08-14 20:00:00"></span></td></tr>'
    )

    download_factor, _upload_factor, deadline = site._parse_promo(row)

    assert download_factor == 0.0
    assert deadline == datetime(2026, 8, 14, 12, 0, 0)


def test_mteam_api_datetime_uses_same_site_timezone() -> None:
    load_all_sites()
    config = get_site_config("mteam")
    site = MTeamSite(
        site_id=config.site_id,
        base_url=config.base_url,
        web_base_url=config.web_base_url,
        category_map=config.category_map,
        client=MagicMock(),
        auth_manager=MagicMock(),
        timezone=config.timezone,
    )

    assert site._parse_datetime("2026-08-14 20:00:00") == datetime(2026, 8, 14, 12, 0, 0)
