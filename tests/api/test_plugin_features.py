"""插件页分层的功能目录（docs/design/plugin-page-tiers.md §2、§3）。"""

from __future__ import annotations

from movieclaw_api.plugins.bundled import bundled_ids
from movieclaw_api.plugins.features import FEATURES, OFFICIAL_HUBS, feature_of, tier_of
from movieclaw_api.plugins.manifest import BUILTIN_MANIFEST


def test_feature_entries_are_real_builtin_plugins_owned_once() -> None:
    builtin = {e.id for e in BUILTIN_MANIFEST}
    seen: dict[str, str] = {}
    for feature in FEATURES:
        assert feature.entries, feature.key
        for entry in feature.entries:
            assert entry in builtin, f"功能「{feature.title}」引用了不存在的内置插件 {entry}"
            assert entry not in seen, f"{entry} 同时属于 {seen[entry]} 与 {feature.key}"
            seen[entry] = feature.key
    assert len({f.key for f in FEATURES}) == len(FEATURES)


def test_feature_copy_is_for_users_and_links_stay_on_site() -> None:
    for feature in FEATURES:
        text = feature.title + feature.description
        # 说明给用户看：不出现插件 id 与实现细节
        assert "plugins.yaml" not in text and "." not in feature.title
        assert not any(entry in feature.description for entry in feature.entries)
        href = feature.settings_href
        assert href is None or (href.startswith("/") and not href.startswith("//"))


def test_every_builtin_lands_in_exactly_one_tier() -> None:
    bundled = bundled_ids()
    for entry in BUILTIN_MANIFEST:
        tier = tier_of(entry.id, bundled=bundled)
        assert tier in ("feature", "official", "system")
        assert (tier == "feature") == (feature_of(entry.id) is not None)
    # 随带插件包（可被插件包替换）与它们依赖的中枢是官方插件；核心模块默认是系统模块
    for entry_id in (*bundled, *OFFICIAL_HUBS):
        assert tier_of(entry_id, bundled=bundled) == "official"
    assert tier_of("core.database", bundled=bundled) == "system"
    assert tier_of("some.new-builtin", bundled=bundled) == "system"


def test_switchable_features_can_be_stopped_without_side_effects() -> None:
    """可停用的功能：组成插件都允许关闭、能运行中重载，功能外没有插件依赖它们提供的服务。"""
    by_id = {e.id: e for e in BUILTIN_MANIFEST}
    for feature in (f for f in FEATURES if f.switchable):
        members = [by_id[entry] for entry in feature.entries]
        for entry in members:
            assert entry.plugin.disableable, f"{entry.id} 须 disableable 才能放进可停用的功能"
            assert entry.plugin.reloadable, f"{entry.id} 须 reloadable 才能运行中切换"
            assert not entry.plugin.critical
        provided = {key.name for entry in members for key in entry.plugin.provides}
        outside = [
            e.id
            for e in BUILTIN_MANIFEST
            if e.id not in feature.entries and any(k.name in provided for k in e.plugin.inject)
        ]
        assert outside == [], f"停用「{feature.title}」会连带 {outside}"


def test_ai_assistant_is_core_not_a_feature() -> None:
    """AI 助手是核心：不在功能目录里，也不能被补丁关掉。"""
    by_id = {e.id: e for e in BUILTIN_MANIFEST}
    for entry_id in ("agent.runs", "agent.session-index", "agent.attachments"):
        assert feature_of(entry_id) is None
        assert not by_id[entry_id].plugin.disableable
