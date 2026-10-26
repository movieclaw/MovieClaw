from . import test_auth as auth

client = auth.client


def test_saved_preferences_response_follows_request_language(client):
    auth._bootstrap(client)
    for locale, message in [("en", "Interface settings saved"), ("zh-Hans", "界面设置已保存")]:
        response = client.put(
            "/api/v1/ui/preferences", json={}, headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        assert response.json()["message"] == message
        assert response.json()["success"] is True


def test_created_library_message_keeps_user_names_in_their_original_language(client, tmp_path):
    auth._bootstrap(client)
    media = tmp_path / "media"
    media.mkdir()
    response = client.post(
        "/api/v1/libraries",
        json={"name": "自定义库", "kind": "video", "source": "local", "root_paths": [str(media)]},
        headers={"Accept-Language": "en"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["name"] == "自定义库"
    assert response.json()["message"] == 'Created library "自定义库"; scanning existing files'
