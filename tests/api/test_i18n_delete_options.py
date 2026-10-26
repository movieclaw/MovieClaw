"""Built-in deletion option copy follows each reader while plugin copy stays compatible."""

from . import test_remove_source as removal

client = removal.client
downloader = removal.downloader


def test_builtin_delete_option_names_follow_each_request(client, tmp_path, downloader):
    from movieclaw_api.services.library.delete_participants import participants
    from movieclaw_api.services.remove_source import PARTICIPANT

    seeded = removal.seed_linked_show(client, tmp_path)
    for locale, label in (
        ("en", "Also delete download tasks and source files"),
        ("zh-Hans", "同时删除下载任务和源文件"),
        ("en", "Also delete download tasks and source files"),
    ):
        response = client.get(
            f"{removal.base(seeded)}/delete-preview", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        option = next(o for o in response.json()["data"]["options"] if o["key"] == removal.KEY)
        assert option["label"] == label
        assert option["available"] is True
    assert PARTICIPANT.label == "同时删除下载任务和源文件"
    assert participants("item")[removal.KEY] is PARTICIPANT
    response = client.delete(
        removal.base(seeded), params={"options": removal.KEY}, headers={"Accept-Language": "en"}
    )
    assert response.status_code == 200, response.text
    assert (
        response.json()["data"]["follow_ups"][0]["label"]
        == "Also delete download tasks and source files"
    )
