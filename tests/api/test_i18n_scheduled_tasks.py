"""Only declared task display references translate; ordering and schedules remain stable."""

from types import SimpleNamespace

from movieclaw_api.api.routes.scheduled_tasks import _view
from movieclaw_api.i18n import use_locale
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_scheduler.registry import TaskDefinition, get_task

from . import test_scheduled_tasks_api as scheduled

client = scheduled.client


def test_registered_labels_follow_reader_without_reordering_or_schedule_changes(client):
    results = [
        client.get("/api/v1/scheduled-tasks", headers={"Accept-Language": language}).json()["data"]
        for language in ("en", "zh-Hans", "en")
    ]
    assert results[0] == results[2]
    assert [row["key"] for row in results[0]] == [row["key"] for row in results[1]]
    assert results[0]
    for english, chinese in zip(results[0], results[1], strict=True):
        definition = get_task(english["key"])
        assert definition is not None
        assert (chinese["title"], chinese["description"]) == (
            definition.title,
            definition.description,
        )
        assert english["title"] != chinese["title"]
        assert english["description"] != chinese["description"]
        assert not any("\u3400" <= c <= "\u9fff" for c in english["title"] + english["description"])
        assert {k: v for k, v in english.items() if k not in ("title", "description")} == {
            k: v for k, v in chinese.items() if k not in ("title", "description")
        }


def test_unmarked_or_unknown_plugin_references_preserve_original_names():
    async def handler():
        pass

    row = SimpleNamespace(
        task_key="raw:plugin",
        enabled=False,
        trigger_type=TriggerType.CRON,
        interval_seconds=None,
        cron_expr="30 3 * * *",
        last_run_at=None,
        next_run_at=None,
    )
    for key in (None, "plugin.unknown.title"):
        definition = TaskDefinition(
            key=row.task_key,
            title="用户插件标题",
            description="原始插件说明",
            handler=handler,
            default_trigger_type=TriggerType.CRON,
            default_cron=row.cron_expr,
            title_key=key,
            description_key=key,
        )
        for language in ("en", "zh-Hans"):
            with use_locale(language):
                view = _view(row, definition)
            assert view.title == definition.title and view.description == definition.description
            assert view.key == row.task_key and view.cron_expr == row.cron_expr
