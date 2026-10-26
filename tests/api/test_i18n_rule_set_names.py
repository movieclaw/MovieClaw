"""Only system-seeded names carry translation provenance; names remain user data."""

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.schemas.subscription import RuleSetView
from movieclaw_api.services.rule_sets import RuleSetService

from . import test_rule_set_scope as scope

db = scope.db


async def test_seeded_name_keeps_identity_across_language_and_spec_edits(db):
    async with db.session() as session:
        service = RuleSetService(session)
        row = await service.ensure_default()
        assert row.name == "默认规则组"
        assert row.name_key == "subscription.rules.defaultName"
        view = RuleSetView.from_model(row)
        assert view.name == row.name and view.name_key == row.name_key
        for locale, name in (("en", "Default rule set"), ("zh-Hans", row.name)):
            with use_locale(locale):
                pick = await service.pick("tv", None)
                assert name in render_value(pick.reason_message)
        await service.update(row.id, name=row.name, spec={"min_seeders": 2})
        assert row.name_key == "subscription.rules.defaultName"
        await service.update(row.id, name="我的默认组", spec={})
        assert row.name_key is None
        with use_locale("en"):
            assert "我的默认组" in render_value((await service.pick("tv", None)).reason_message)


async def test_user_name_matching_builtin_copy_is_never_translated(db):
    async with db.session() as session:
        service = RuleSetService(session)
        row = await service.create("默认规则组", {})
        await service.set_default(row.id)
        assert row.name_key is None
        with use_locale("en"):
            pick = await service.pick("tv", None)
            assert "默认规则组" in render_value(pick.reason_message)
            assert "Default rule set" not in render_value(pick.reason_message)
