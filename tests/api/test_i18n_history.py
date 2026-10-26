from __future__ import annotations

from sqlmodel import select

from . import test_auth as auth

client = auth.client


def test_stored_notice_renders_for_each_reader_and_keeps_chinese_for_rollback(client):
    from movieclaw_api.i18n import use_locale
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity, SystemNotice

    auth._bootstrap(client)

    async def create():
        with use_locale("en"):
            async with get_database().session() as session:
                await upsert_notice(
                    session,
                    dedupe_key="downloader:test",
                    severity=NoticeSeverity.ERROR,
                    source="downloader",
                    title_key="notify.downloader.connectionTitle",
                    message_key="notify.downloader.connectionBody",
                    message_params={"name": "qBittorrent", "reason": "Connection refused"},
                )

    client.portal.call(create)
    english = client.get("/api/v1/system/notices", headers={"Accept-Language": "en"}).json()["data"]
    assert english[0]["title"] == "Downloader qBittorrent could not connect"
    assert (
        english[0]["message"]
        == "Connection test failed for downloader qBittorrent: Connection refused"
    )
    chinese = client.get("/api/v1/system/notices", headers={"Accept-Language": "zh-Hans"}).json()[
        "data"
    ]
    assert chinese[0]["title"] == "下载器「qBittorrent」连接失败"

    async def stored():
        async with get_database().session() as session:
            row = (await session.execute(select(SystemNotice))).scalar_one()
            return row.title, row.message, row.message_key, row.message_params

    title, message, key, params = client.portal.call(stored)
    assert title == chinese[0]["title"]
    assert message == "下载器「qBittorrent」连接测试失败：Connection refused"
    assert key == "notify.downloader.connectionBody"
    assert params["name"] == "qBittorrent"


def test_old_fixed_notice_can_be_translated_and_unknown_legacy_text_stays_intact(client):
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import SystemNotice

    auth._bootstrap(client)

    async def create():
        async with get_database().session() as session:
            session.add(
                SystemNotice(
                    dedupe_key="legacy:known",
                    severity="warning",
                    source="system",
                    title="测试通知",
                    message="能看到这条，说明这台设备能收到这台服务器的通知。",
                )
            )
            session.add(
                SystemNotice(
                    dedupe_key="legacy:unknown",
                    severity="error",
                    source="system",
                    title="Legacy plugin",
                    message="插件自带的旧原文",
                )
            )
            await session.commit()

    client.portal.call(create)
    rows = client.get("/api/v1/system/notices", headers={"Accept-Language": "en"}).json()["data"]
    assert rows[0]["message"] == "插件自带的旧原文"
    assert rows[1]["title"] == "Test notification"
