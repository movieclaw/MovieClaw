"""用户自定义站点配置目录的加载测试。

内置站点 YAML 随镜像分发，容器更新会被覆盖；用户自己适配的站点 YAML 放在
data/ 卷下的自定义目录（默认 data/site-configs/），启动时在内置目录之后加载。

覆盖的行为：
1. 用户目录里的新站点被注册；
2. 与内置站点同 site_id 的用户配置覆盖内置配置；
3. 单个坏文件（YAML 语法错误 / 缺 site_id / custom_class 导入失败 /
   字段类型或写法非法）只跳过，不影响其它站点加载；
4. 目录不存在时自动创建并播种模板文件；
5. 不传用户目录时行为与之前完全一致（全部内置站点可用）。
"""
from __future__ import annotations

from pathlib import Path

import pytest

from movieclaw_tracker.exceptions import SiteNotFoundError
from movieclaw_tracker.registry import get_site_config, list_sites, load_all_sites

_USER_SITE_YAML = """\
site_id: mysite
display_name: My Site
base_url: https://pt.mysite.example
framework: nexusphp
categories:
  movie: [401]
"""


@pytest.fixture(autouse=True)
def _restore_builtin_registry():
    """每个测试结束后恢复纯内置注册表，避免污染同进程的其它测试。"""
    yield
    load_all_sites()


def test_user_site_registered(tmp_path: Path) -> None:
    (tmp_path / "mysite.yaml").write_text(_USER_SITE_YAML, encoding="utf-8")

    load_all_sites(tmp_path)

    config = get_site_config("mysite")
    assert config.display_name == "My Site"
    assert config.base_url == "https://pt.mysite.example"
    # 内置站点依然全部在场
    assert any(c.site_id == "mteam" for c in list_sites())


def test_user_config_overrides_builtin(tmp_path: Path) -> None:
    (tmp_path / "ssd.yaml").write_text(
        """\
site_id: ssd
display_name: SSD 用户覆盖版
base_url: https://springsunday.example
framework: nexusphp
""",
        encoding="utf-8",
    )

    load_all_sites(tmp_path)

    config = get_site_config("ssd")
    assert config.display_name == "SSD 用户覆盖版"
    assert config.base_url == "https://springsunday.example"
    # 覆盖不产生重复注册
    assert sum(1 for c in list_sites() if c.site_id == "ssd") == 1


@pytest.mark.parametrize(
    "bad_content",
    [
        "site_id: [unclosed",  # YAML 语法错误
        "display_name: 缺少 site_id\nframework: nexusphp\n",  # 缺必填字段
        "site_id: broken\nframework: nexusphp\ncustom_class: no.such.module.Cls\n",  # 导入失败
        "site_id: badfw\nframework: unknown_framework\n",  # 未知框架
        # 选择器键名拼错（dataclasses.replace 抛 TypeError）
        "site_id: broken\nframework: nexusphp\nselectors:\n  torrent_row_cs: 'tr'\n",
        # selectors 写成列表而非映射
        "site_id: broken\nframework: nexusphp\nselectors:\n  - torrent_row_css\n",
        # 促销系数写成非数字（float 转换抛 ValueError）
        "site_id: broken\nframework: nexusphp\nselectors:\n"
        "  promo_download_rules:\n    'img.pro_free': free\n",
        # categories 写成列表而非映射
        "site_id: broken\nframework: nexusphp\ncategories:\n  - movie\n",
        # categories 的值写成标量而非列表（int 不可迭代）
        "site_id: broken\nframework: nexusphp\ncategories:\n  movie: 401\n",
    ],
)
def test_bad_user_file_does_not_break_others(tmp_path: Path, bad_content: str) -> None:
    (tmp_path / "bad.yaml").write_text(bad_content, encoding="utf-8")
    (tmp_path / "mysite.yaml").write_text(_USER_SITE_YAML, encoding="utf-8")

    load_all_sites(tmp_path)

    # 好文件正常加载，坏文件被跳过
    assert get_site_config("mysite").display_name == "My Site"
    for bad_id in ("broken", "badfw"):
        with pytest.raises(SiteNotFoundError):
            get_site_config(bad_id)


def test_auth_supported_as_string_falls_back_to_default(tmp_path: Path) -> None:
    """auth.supported 误写成字符串（而非列表）时不逐字符解析，按框架默认值兜底。"""
    (tmp_path / "mysite.yaml").write_text(
        _USER_SITE_YAML + "auth:\n  supported: cookie\n", encoding="utf-8"
    )

    load_all_sites(tmp_path)

    config = get_site_config("mysite")
    assert config.supported_auth_types == ("cookie", "credential")


def test_user_dir_created_with_template(tmp_path: Path) -> None:
    user_dir = tmp_path / "site-configs"
    assert not user_dir.exists()

    load_all_sites(user_dir)

    assert user_dir.is_dir()
    template = user_dir / "_template.yaml"
    assert template.exists()
    assert "site_id" in template.read_text(encoding="utf-8")
    # 模板文件本身不会被注册为站点
    with pytest.raises(SiteNotFoundError):
        get_site_config("your_site_id")


def test_without_user_dir_builtin_sites_intact() -> None:
    load_all_sites()

    site_ids = {c.site_id for c in list_sites()}
    assert {"mteam", "ssd", "ttg", "chdbits"} <= site_ids


def test_custom_class_never_imports_arbitrary_modules(tmp_path: Path, monkeypatch) -> None:
    """数据文件不能执行代码：custom_class 只认内置站点类与插件注册的类（plugin-phase2b.md §6）。"""
    import sys

    marker = tmp_path / "imported.marker"
    module_dir = tmp_path / "pkgs"
    module_dir.mkdir()
    (module_dir / "evil_site_module.py").write_text(
        f"open({str(marker)!r}, 'w').write('ran')\nclass Evil: pass\n", encoding="utf-8"
    )
    monkeypatch.syspath_prepend(str(module_dir))
    configs = tmp_path / "configs"
    configs.mkdir()
    (configs / "evil.yaml").write_text(
        "site_id: evil\nframework: nexusphp\ncustom_class: evil_site_module.Evil\n",
        encoding="utf-8",
    )
    (configs / "mysite.yaml").write_text(_USER_SITE_YAML, encoding="utf-8")

    load_all_sites(configs)

    assert not marker.exists(), "custom_class 不能导入白名单之外的模块"
    assert "evil_site_module" not in sys.modules
    assert get_site_config("mysite").display_name == "My Site"
    with pytest.raises(SiteNotFoundError):
        get_site_config("evil")


def test_builtin_site_classes_resolve_by_short_name_and_legacy_path(tmp_path: Path) -> None:
    from movieclaw_tracker.sites.custom.mteam import MTeamSite

    (tmp_path / "short.yaml").write_text(
        "site_id: shortmt\nframework: api\ncustom_class: mteam\n", encoding="utf-8"
    )
    (tmp_path / "legacy.yaml").write_text(
        "site_id: legacymt\nframework: api\n"
        "custom_class: movieclaw_tracker.sites.custom.mteam.MTeamSite\n",
        encoding="utf-8",
    )
    load_all_sites(tmp_path)
    assert get_site_config("shortmt").site_class is MTeamSite
    assert get_site_config("legacymt").site_class is MTeamSite
    # 内置的四个站点（M-Team、SunnyPT、OurBits、TTG）照常加载
    for site_id in ("mteam", "sunnypt", "ourbits", "ttg"):
        get_site_config(site_id)


def test_plugin_site_classes_and_data_packs(tmp_path: Path) -> None:
    from movieclaw_tracker import registry
    from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite

    class AcmeSite(NexusPHPSite):
        pass

    pack = tmp_path / "pack"
    pack.mkdir()
    (pack / "acme.yaml").write_text(
        "site_id: acmepack\nframework: nexusphp\ncustom_class: 'acme.sites:AcmeSite'\n"
        "base_url: https://acme.example\ncategories:\n  movie: [1]\n",
        encoding="utf-8",
    )
    with pytest.raises(TypeError):
        registry.register_site_class("bad", object)  # type: ignore[arg-type]
    registry.register_site_class("acme.sites:AcmeSite", AcmeSite)
    registry.register_data_pack("acme.sites:pack", pack)
    try:
        load_all_sites()
        assert get_site_config("acmepack").site_class is AcmeSite
    finally:
        registry.unregister_data_pack("acme.sites:pack")
        registry.unregister_site_class("acme.sites:AcmeSite")
    load_all_sites()
    with pytest.raises(SiteNotFoundError):
        get_site_config("acmepack")
