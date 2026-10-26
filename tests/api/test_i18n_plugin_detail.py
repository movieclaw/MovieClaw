"""Reader-specific capability labels preserve kernel data, raw author labels and machine fields."""

from movieclaw_kernel.contracts import CATALOG

from . import test_plugin_events as events
from .test_plugin_detail import app_env, start  # noqa: F401

package_data_dir = events.data_dir


def test_capability_labels_follow_each_request_without_changing_registry_or_files(app_env):  # noqa: F811
    source = app_env / "plugins.yaml"
    original = source.read_bytes()
    with start() as client:
        doc = CATALOG["library.ingest.completed"].doc
        rows = []
        for locale in ("en", "zh-Hans", "en"):
            response = client.get(
                "/api/v1/app/plugins/acme-detail", headers={"Accept-Language": locale}
            )
            assert response.status_code == 200, response.text
            rows.append(response.json()["data"])
            assert source.read_bytes() == original
            assert CATALOG["library.ingest.completed"].doc == doc
        english, chinese, again = rows
        assert english["adds"] == again["adds"]
        assert len(english["adds"]) == len(chinese["adds"])
        assert [(r["kind"], r["href"]) for r in english["adds"]] == [
            (r["kind"], r["href"]) for r in chinese["adds"]
        ]
        assert all(set(row) == {"kind", "title", "detail", "href"} for row in english["adds"])
        command = next(row for row in english["adds"] if row["kind"] == "command")
        assert command["title"] == "mclaw plugins acme-detail recent"
        assert command["detail"] == "Available to the AI assistant and command line"
        trigger = next(row for row in english["adds"] if row["kind"] == "trigger")
        assert trigger["title"] == f"Automatically processes events after “{doc}”"
        assert trigger["detail"] == "Retained across restarts and retried after failures"
        assert next(row for row in chinese["adds"] if row["kind"] == "trigger")["title"] == (
            f"「{doc}」后会自动处理"
        )
        assert english["consumers"][0]["events"] == chinese["consumers"][0]["events"]
        assert english["plugin"]["id"] == chinese["plugin"]["id"] == "acme-detail"
        # The author's default name and unknown contract documentation are preserved verbatim.
        assert english["plugin"]["title"] == chinese["plugin"]["title"] == "详情示例"


def test_every_running_plugin_projects_capabilities_with_the_existing_response_shape(app_env):  # noqa: F811
    from functools import partial

    from movieclaw_api.pipeline import INGEST_STEPS, IngestStep
    from movieclaw_kernel import Entry, plugin

    @plugin("i18n-ingest", title="Fixture ingest")
    async def ingest(ctx):
        ctx.contribute(
            INGEST_STEPS,
            "preview",
            IngestStep(job_type="i18n-ingest:preview", title="Fixture ingest"),
        )

    with start() as client:
        client.portal.call(partial(client.app.state.kernel.mount, Entry("i18n-ingest", ingest)))
        overview = client.get("/api/v1/app/plugins").json()["data"]
        kinds = set()
        for item in overview["plugins"]:
            response = client.get(
                "/api/v1/app/plugins/" + item["id"], headers={"Accept-Language": "en"}
            )
            assert response.status_code == 200, (item["id"], response.text)
            for capability in response.json()["data"]["adds"]:
                assert set(capability) == {"kind", "title", "detail", "href"}
                assert isinstance(capability["title"], str)
                assert isinstance(capability["detail"], str)
                kinds.add(capability["kind"])
        assert {"service", "task", "ingest", "command", "trigger", "decision"} <= kinds


def test_notification_audience_projection_keeps_author_metadata_and_sends_no_event(
    package_data_dir,
):  # noqa: F811
    _, client = events.start()
    with client:
        uploaded = events.upload(client, events.events_package(audience="admins"))
        assert uploaded.status_code == 200, uploaded.text
        approved = events.approve(client, "1.0.0", operations=())
        assert approved.status_code == 200, approved.text
        result = []
        for language in ("en", "zh-Hans", "en"):
            response = client.get(
                "/api/v1/app/plugins/acme-pkg", headers={"Accept-Language": language}
            )
            assert response.status_code == 200, response.text
            result.append(response.json()["data"]["adds"])
        assert result[0] == result[2]
        english = next(row for row in result[0] if row["kind"] == "notification")
        chinese = next(row for row in result[1] if row["kind"] == "notification")
        assert english["title"] == "Sends notifications: 站点配额超限"
        assert english["detail"] == (
            "Sent to Administrators; choose whether to receive it under Account → Notifications"
        )
        assert chinese["title"] == "会发通知：站点配额超限"
        assert chinese["detail"] == "发给管理员；收不收在「账号 → 通知」里开"
