"""高清杜比（HDDolby）站点配置与新域名回归测试（issue #1304）。"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

from movieclaw_tracker import load_all_sites
from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite
from movieclaw_tracker.registry import get_site_config
from movieclaw_tracker.selectors import NexusPHPSelectors

HDDOLBY_PROFILE_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>UHDDolby :: fixture_user</title>
</head>
<body>
  <table id="info_block">
    <tr>
      <td>
        <a href="userdetails.php?id=9527" class="PowerUser_Name"><b>dolby_user</b></a>
        <font class="color_ratio">分享率:</font> 3.50
        <font class="color_uploaded">上传量:</font> 2.50 TB
        <font class="color_downloaded">下载量:</font> 730.00 GB
        <font class="color_bonus">鲸币:</font> 12,345.6
        <img class="arrowup" alt="seeding" /> 18
        <img class="arrowdown" alt="leeching" /> 1
      </td>
    </tr>
  </table>
</body>
</html>
"""


def test_hddolby_yaml_uses_uhddolby_domain() -> None:
    load_all_sites()

    config = get_site_config("hddolby")

    assert config.site_class is NexusPHPSite
    assert config.display_name == "高清杜比 HDDolby"
    assert config.base_url == "https://www.uhddolby.com"
    assert config.supported_auth_types == ("cookie", "credential")
    assert isinstance(config.selectors, NexusPHPSelectors)


async def test_hddolby_profile_requests_new_domain() -> None:
    load_all_sites()
    config = get_site_config("hddolby")
    assert isinstance(config.selectors, NexusPHPSelectors)

    client = MagicMock()
    response = MagicMock()
    response.text = HDDOLBY_PROFILE_HTML
    client.get = AsyncMock(return_value=response)

    site = NexusPHPSite(
        selectors=config.selectors,
        category_map=config.category_map,
        site_id=config.site_id,
        base_url=config.base_url,
        client=client,
        auth_manager=MagicMock(),
    )

    profile = await site.get_user_profile()

    assert profile.username == "dolby_user"
    assert profile.user_id == "9527"
    assert profile.seeding_count == 18
    assert profile.leeching_count == 1
    client.get.assert_awaited_once_with(
        "https://www.uhddolby.com/userdetails.php", params={}
    )
