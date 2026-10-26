"""Real API → device registration → encrypted relay and per-member IM payloads."""

from __future__ import annotations

from datetime import UTC

from . import test_cloud_push as cloud
from . import test_push_cards as cards

world = cloud.world
client = cloud.client
clock = cards.clock


def register_pair(client):
    keys = {}
    for language, timezone, token in (
        ("en", "America/New_York", "ab" * 32),
        ("zh-Hans", "Asia/Shanghai", "cd" * 32),
    ):
        bearer = cloud._app_login(
            client, cloud._ADMIN, installation=f"i18n-{language}-phone", name=language
        )
        _, key = cloud._register(client, bearer, token=token)
        response = cloud._as_app(
            client,
            bearer,
            "GET",
            "/api/v1/auth/me",
            headers={
                "Accept-Language": language,
                "X-MovieClaw-Timezone": timezone,
            },
        )
        assert response.status_code == 200
        keys[token] = key
    return keys


def test_same_event_uses_device_language_and_explicit_member_language_for_im(
    client, world, monkeypatch
):
    cloud._connect(client, world)
    keys = register_pair(client)
    assert client.put("/api/v1/ui/preferences", json={"language": "zh-Hans"}).status_code == 200
    messages = []

    async def deliver(items):
        messages.extend(items)
        return []

    monkeypatch.setattr("movieclaw_api.services.push.im.owners", lambda: {0})
    monkeypatch.setattr("movieclaw_api.services.push.im.deliver", deliver)
    response = client.post("/api/v1/push/me/test", headers={"Accept-Language": "en"})
    assert response.status_code == 200
    payloads = {
        message["token"]: cloud._open(message, keys[message["token"]])
        for message in world.relays["push.test"].messages
    }
    assert payloads["ab" * 32]["title"] == "Test notification"
    assert payloads["cd" * 32]["title"] == "测试通知"
    assert messages[0].text == "测试通知\n能看到这条，说明这台设备能收到这台服务器的通知。"


def test_builder_cache_keeps_device_timezones_separate_and_resets_context(client, world):
    from datetime import datetime

    from movieclaw_api.i18n import current_locale, current_timezone
    from movieclaw_api.i18n.format import absolute_time
    from movieclaw_api.services.push.notify import AlertContent, prepare
    from movieclaw_db.engine import get_database

    cloud._connect(client, world)
    keys = register_pair(client)

    async def build(_session, _member):
        return AlertContent(title=absolute_time(datetime(2026, 10, 23, 12, tzinfo=UTC)))

    async def run():
        before = (current_locale.get(), current_timezone.get())
        async with get_database().session() as session:
            result = await prepare(session, event=None, member_ids={0}, build=build, to_im=False)
        assert (current_locale.get(), current_timezone.get()) == before
        return result

    prepared = client.portal.call(run)
    assert len(prepared.relay) == 2
    assert {cloud._open(item.message, keys[item.token])["title"] for item in prepared.relay} == {
        "Oct 23, 2026, 08:00",
        "2026/10/23 20:00",
    }


def test_real_import_card_and_actions_render_for_each_device(client, world, clock):
    cloud._connect(client, world)
    cloud._create_member(client)
    keys = register_pair(client)
    world.relays["push.test"].messages.clear()
    show = cards.Show(client, clock)
    show.seed(episodes=2)
    show.grab([1, 2])
    show.land([1, 2])
    show.advance(180)
    english = cloud._open(cards._expect(world, "ab" * 32, 1)[0], keys["ab" * 32])
    chinese = cloud._open(cards._expect(world, "cd" * 32, 1)[0], keys["cd" * 32])
    assert english["title"] == f"{cards.TITLE}: all of Season 1 is in your library"
    assert english["body"] == "All 2 episodes are ready. Tap to start at Episode 1"
    assert [action["title"] for action in english["actions"]] == [
        "Play Episode 1",
        "View all episodes",
        "Mute notifications for this series",
    ]
    assert chinese["title"] == f"{cards.TITLE} 第 1 季已全部入库"
    assert chinese["body"] == "2 集都能看了，点开从第 1 集开始"
    assert chinese["actions"][0]["title"] == "播放第 1 集"
