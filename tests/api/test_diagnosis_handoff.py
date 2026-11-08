"""诊断工单：三类待办各自能组装出带现场自检的完整输入。

核心诉求是"给足输入"——工单里必须出现证据本身（目录体检结论、下载器实时
状态、系统已做过的事、与界面一致的动作清单），而不只是告警标题。
"""

from __future__ import annotations

import pytest
import pytest_asyncio

from movieclaw_api.core.config import get_settings
from movieclaw_api.schemas.agent import SessionStartPayload
from movieclaw_api.services.diagnosis_handoff import build_handoff_prompt
from movieclaw_api.services.download_health import landing_group_key
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    Job,
    JobEvent,
    MediaItem,
    RuleSet,
    Subscription,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    SystemNotice,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_db.models.downloader_client import ClientType, DownloaderClient
from movieclaw_db.models.site_credential import ConfigStatus


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'handoff.db'}")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    get_settings.cache_clear()


@pytest.mark.asyncio
async def test_downloader_landing_notice_prompt_runs_live_path_probe(db, tmp_path):
    """目录级落点红灯 → 工单现场 stat 映射目录，把"目录为空、重启容器"这个结论端出来，
    并列出被刹车的在途投递与动作清单。"""
    empty = tmp_path / "download"
    empty.mkdir()
    async with db.session() as session:
        dl = DownloaderClient(
            name="qb",
            client_type=ClientType.QBITTORRENT,
            url="http://qb:8080",
            status=ConfigStatus.ACTIVE,
            path_mappings=[{"local": str(empty), "remote": "/downloads"}],
        )
        session.add(dl)
        await session.flush()
        media = MediaItem(kind="tv", tmdb_id=1, title="剧A", original_title="A")
        rule = RuleSet(name="r", spec={})
        session.add_all([media, rule])
        await session.flush()
        sub = Subscription(media_item_id=media.id, kind="tv", rule_set_id=rule.id)
        session.add(sub)
        await session.flush()
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub.id,
                downloader_id=dl.id,
                info_hash="a" * 40,
                torrent_title="Show.A.S01",
                save_path=str(empty),
                units=[[1, 1]],
                status="replacement_pending",
                last_progress_at=utcnow(),
            )
        )
        key = landing_group_key(dl.id, str(empty))
        session.add(
            SystemNotice(
                dedupe_key=key,
                severity="error",
                source="downloader",
                title="下载器「qb」的目录 movieclaw 看不到",
                message="x",
                payload={"group_key": key, "downloader_id": dl.id, "local_dir": str(empty)},
            )
        )
        session.add(
            SystemNotice(
                dedupe_key=f"subscription.landing:{sub.id}:{'a' * 40}",
                severity="error",
                source="subscription",
                title="「Show.A.S01」下载完成但无法入库",
                message="y",
                payload={
                    "subscription_id": sub.id,
                    "info_hash": "a" * 40,
                    "size_bytes": 3 * 2**30,
                    "grouped_under": key,
                },
            )
        )
        await session.commit()
        notice_id = (
            await session.execute(
                __import__("sqlmodel").select(SystemNotice.id).where(SystemNotice.dedupe_key == key)
            )
        ).scalar_one()

    async with db.session() as session:
        result = await build_handoff_prompt(session, "notice", str(notice_id))

    p = result.prompt
    assert "empty" in p and "重启" in p  # 现场体检结论，不是三选一
    assert "被收编的单种子告警 1 条" in p and "3.00 GB" in p
    assert "自动换源已刹车" in p and "Show.A.S01" in p  # 系统已做过的事 + 被刹车的投递
    assert "dl.verify" in p and "破坏性" not in p.split("## 你可以执行的动作")[0]
    assert "不要编造" in p


@pytest.mark.asyncio
async def test_job_prompt_includes_error_actions_and_events(db):
    async with db.session() as session:
        job = Job(
            id="job_test1",
            job_type="library.ingest",
            subject="Some.Show.S01",
            status="blocked",
            input_data={"rule_id": 1},
            progress={"message": "等待人工认领"},
            error={
                "code": "INGEST_IDENTITY_REQUIRED",
                "message": "无法自动识别该条目",
                "actions": [{"type": "open_settings", "label": "去自动入库认领"}],
            },
        )
        session.add(job)
        await session.flush()
        session.add(
            JobEvent(job_id=job.id, revision=1, event_type="blocked", payload={"why": "no match"})
        )
        await session.commit()
    async with db.session() as session:
        result = await build_handoff_prompt(session, "job", "job_test1")
    p = result.prompt
    assert "INGEST_IDENTITY_REQUIRED" in p and "去自动入库认领" in p
    assert "设置 → 自动入库" in p
    assert "[blocked]" in p and "no match" in p
    assert "阻塞任务占着资源锁不能忽略" in p


@pytest.mark.asyncio
async def test_long_job_handoff_prompt_fits_session_start_contract(db):
    """交接工单最终会原样成为 session.start.content，不能超过其 4000 字符契约。"""
    async with db.session() as session:
        job = Job(
            id="job_long_subtitle_error",
            job_type="subtitle.generate",
            subject="Movie.mkv",
            status="failed",
            progress={"message": "翻译失败", "details": {"validation_retries": 13}},
            error={
                "code": "SUBTITLE_TRANSLATION_ABORTED",
                "message": "返回内容未通过校验；" * 600,
                "actions": [{"type": "handoff_agent", "label": "交给 Agent"}],
            },
        )
        session.add(job)
        await session.commit()

    async with db.session() as session:
        result = await build_handoff_prompt(session, "job", job.id)

    payload = SessionStartPayload.model_validate({"content": result.prompt})
    assert payload.content == result.prompt
    assert "job_long_subtitle_error" in result.prompt
    assert "SUBTITLE_TRANSLATION_ABORTED" in result.prompt
    assert "工单内容已截断" in result.prompt
    assert "## 你可以执行的动作" in result.prompt
    assert "## 请你做什么" in result.prompt


@pytest.mark.asyncio
async def test_long_notice_and_download_handoffs_fit_session_start_contract(db):
    """同一工单生成器服务告警与下载任务，两类长时间线也必须遵守会话上限。"""
    async with db.session() as session:
        notice = SystemNotice(
            dedupe_key="test:long-notice",
            severity="error",
            source="test",
            title="超长告警",
            message="现场诊断详情；" * 800,
            payload={},
        )
        media = MediaItem(kind="tv", tmdb_id=3, title="剧C", original_title="C")
        rule = RuleSet(name="r3", spec={})
        session.add_all([notice, media, rule])
        await session.flush()
        sub = Subscription(media_item_id=media.id, kind="tv", rule_set_id=rule.id)
        session.add(sub)
        await session.flush()
        session.add_all(
            [
                SubscriptionDownloadAttempt(
                    subscription_id=sub.id,
                    info_hash="c" * 40,
                    torrent_title="Show.C.S01E01",
                    units=[[1, 1]],
                    status="active",
                    last_progress_at=utcnow(),
                ),
                SubscriptionActivity(
                    subscription_id=sub.id,
                    type="download_failed",
                    message="下载器返回的超长诊断；" * 800,
                    payload={},
                ),
            ]
        )
        await session.commit()
        notice_id = notice.id

    async with db.session() as session:
        prompts = [
            (await build_handoff_prompt(session, "notice", str(notice_id))).prompt,
            (await build_handoff_prompt(session, "download", "C" * 40)).prompt,
        ]

    for prompt in prompts:
        SessionStartPayload.model_validate({"content": prompt})
        assert "工单内容已截断" in prompt
        assert "## 请你做什么" in prompt


@pytest.mark.asyncio
async def test_download_prompt_reports_missing_torrent_and_timeline(db):
    async with db.session() as session:
        media = MediaItem(kind="tv", tmdb_id=2, title="剧B", original_title="B")
        rule = RuleSet(name="r2", spec={})
        session.add_all([media, rule])
        await session.flush()
        sub = Subscription(media_item_id=media.id, kind="tv", rule_set_id=rule.id)
        session.add(sub)
        await session.flush()
        session.add(
            WantedItem(
                subscription_id=sub.id,
                media_item_id=media.id,
                season_number=1,
                episode_number=8,
                status=WantedStatus.GRABBED,
                info_hash="b" * 40,
            )
        )
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub.id,
                info_hash="b" * 40,
                torrent_title="Show.B.S01E08",
                units=[[1, 8]],
                status="active",
                last_progress_at=utcnow(),
            )
        )
        session.add(
            SubscriptionActivity(
                subscription_id=sub.id,
                type="download_stalled",
                message="下载已连续 15 分钟没有进度",
                payload={},
            )
        )
        await session.commit()
    async with db.session() as session:
        result = await build_handoff_prompt(session, "download", "B" * 40)
    p = result.prompt
    assert "《剧B》S01E08" in p
    assert "都查不到该种子" in p  # 没有可用下载器时如实说明，不伪造状态
    assert "[download_stalled]" in p
    assert "删除下载任务" in p and "破坏性" in p
