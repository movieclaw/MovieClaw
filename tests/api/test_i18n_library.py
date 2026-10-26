"""A user editing a busy library receives a translated error with stable references."""

from movieclaw_api.api.routes import libraries
from movieclaw_api.services.library.scan import ScanPhase

from . import test_libraries as original

client = original.client


def test_library_errors_and_nested_phase_follow_each_request(client, tmp_path, monkeypatch):
    root = tmp_path / "movies"
    root.mkdir()
    library = original._create(client, name="我的片库", kind="movie", root=str(root))
    monkeypatch.setattr(libraries, "busy_phase", lambda _id: ScanPhase.PROBING)
    for language, expected in (
        (
            "en",
            '"我的片库" is probing media specifications. '
            "Wait for the current task before editing or deleting it.",
        ),
        ("zh-Hans", "「我的片库」正在补探介质规格，暂不能编辑或删除；请等当前任务完成"),
    ):
        response = client.post(
            f"/api/v1/libraries/{library['id']}/path-reconciliations",
            json={"old_root": str(tmp_path / "old"), "new_root": str(root)},
            headers={"Accept-Language": language},
        )
        assert response.status_code == 409, response.text
        error = response.json()
        assert error["message"] == expected
        assert error["message_key"] == "errors.library.busyPhase"
        assert error["params"]["phase"]["message_key"] == "activity.library.probing"
    response = client.delete(
        f"/api/v1/libraries/{library['id']}/cover", headers={"Accept-Language": "en"}
    )
    assert response.status_code == 404
    assert response.json()["message"] == "This library has no custom cover"
