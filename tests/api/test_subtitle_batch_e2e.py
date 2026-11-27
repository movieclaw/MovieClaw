"""Issue #1282 端到端验证：整季批量 AI 字幕生成面对严苛并发/RPM 限流反代端点。

用真实 FastAPI 路由、真实 SQLite JobDispatcher(max_parallel=4)、真实加密落库的
LlmProvider、真实 OpenAIProtocolBase/AsyncOpenAI 客户端，以及运行在本地 TCP 端口
的真实 OpenAI 兼容 HTTP 假网关，完整验证：
1. 严苛单并发 + RPM 节奏限流的网关下一次性提交整季 6 集，零配置全量成功、零失败堆叠、
   零重复计费，且同期提交的常规后台任务不被字幕队列饿死；
2. 持续限流窗口超出单轮块内重试后平稳转入 retry_wait（而非 failed 刷屏），限流解除后
   自动从断点续译完成且已翻译块不重复消耗模型额度。
"""

from __future__ import annotations

import asyncio
import json
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.deps import require_admin, require_login
from movieclaw_api.app import create_app
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import jobs
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.llm_config import _runtime_router
from movieclaw_api.services.subtitle_gen import sync, tasks, translate
from movieclaw_api.settings import init_setting_store, reset_setting_store
from movieclaw_db.crypto import init_secret_box
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import FileSource, JobStatus, Library, LibraryFile
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
from movieclaw_media.models import MediaKind


class _StrictRateLimitProxy:
    """模拟 Gemini CLI 反代 / 免费额度端点：强制单并发 + 最小发车间隔，超速直接回 HTTP 429。"""

    def __init__(self, *, max_in_flight: int = 1, min_spacing: float = 0.05) -> None:
        self.max_in_flight = max_in_flight
        self.min_spacing = min_spacing
        self.latency = 0.02
        self.force_429 = False
        self.force_429_after_translate_ok: int | None = None

        self._lock = threading.Lock()
        self._in_flight = 0
        self._last_accepted_at = 0.0
        self.peak_in_flight = 0
        self.rate_limits = 0
        self.ok_requests = 0
        self.translate_ok = 0
        self.delivered_per_film: Counter[tuple[str, int]] = Counter()
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> str:
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:  # noqa: A002
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length).decode("utf-8"))
                messages = body.get("messages", [])
                system = next((m["content"] for m in messages if m.get("role") == "system"), "")
                user = next(
                    (m["content"] for m in reversed(messages) if m.get("role") == "user"), ""
                )
                model = body.get("model", "gemini-proxy")

                # 连接测试 ping 直接放行
                if (
                    "找出其中反复出现的人名" not in user
                    and "翻译下列对白：" not in user
                    and "压缩改写" not in user
                ):
                    self._send_completion(model, "pong")
                    return

                with proxy._lock:
                    now = time.monotonic()
                    too_many = proxy._in_flight >= proxy.max_in_flight
                    too_fast = (
                        proxy.min_spacing > 0
                        and proxy._last_accepted_at > 0
                        and (now - proxy._last_accepted_at) < proxy.min_spacing
                    )
                    forced = proxy.force_429 or (
                        proxy.force_429_after_translate_ok is not None
                        and proxy.translate_ok >= proxy.force_429_after_translate_ok
                    )
                    if forced or too_many or too_fast:
                        proxy.rate_limits += 1
                        self._send_429()
                        return
                    proxy._in_flight += 1
                    proxy.peak_in_flight = max(proxy.peak_in_flight, proxy._in_flight)
                    proxy._last_accepted_at = now

                try:
                    if proxy.latency:
                        time.sleep(proxy.latency)
                    if "找出其中反复出现的人名" in user:
                        content = json.dumps(
                            {"items": [{"src": "Neo", "dst": "尼奥"}]}, ensure_ascii=False
                        )
                    elif "压缩改写" in user:
                        items = json.loads(user.rstrip().rsplit("\n", 1)[-1])
                        shorter = [
                            {"i": item["i"], "t": item["t"][: max(4, item["max_chars"])]}
                            for item in items
                        ]
                        content = json.dumps({"items": shorter}, ensure_ascii=False)
                    else:
                        marker = "翻译下列对白："
                        items = json.loads(user[user.index(marker) + len(marker) :].strip())
                        film_tag = system.splitlines()[0]
                        bilingual_mode = "双语" in system
                        translated = []
                        for item in items:
                            idx = int(item["i"])
                            text = f"译文{idx}号\nLine {idx}" if bilingual_mode else f"译文{idx}号"
                            translated.append({"i": idx, "t": text})
                            with proxy._lock:
                                proxy.delivered_per_film[(film_tag, idx)] += 1
                        with proxy._lock:
                            proxy.translate_ok += 1
                        content = json.dumps({"items": translated}, ensure_ascii=False)
                    with proxy._lock:
                        proxy.ok_requests += 1
                    self._send_completion(model, content)
                finally:
                    with proxy._lock:
                        proxy._in_flight -= 1

            def _send_429(self) -> None:
                payload = json.dumps(
                    {
                        "error": {
                            "message": "Rate limit exceeded on CLI proxy",
                            "type": "rate_limit_exceeded",
                            "code": "rate_limit_exceeded",
                        }
                    }
                ).encode("utf-8")
                self.send_response(429)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def _send_completion(self, model: str, content: str) -> None:
                payload = json.dumps(
                    {
                        "id": "proxy-resp",
                        "object": "chat.completion",
                        "created": int(time.time()),
                        "model": model,
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": content},
                                "finish_reason": "stop",
                            }
                        ],
                        "usage": {
                            "prompt_tokens": 120,
                            "completion_tokens": 60,
                            "total_tokens": 180,
                        },
                    },
                    ensure_ascii=False,
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return f"http://127.0.0.1:{port}/v1"

    def close(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None


def _write_english_srt(path: Path, cue_count: int) -> list[str]:
    blocks: list[str] = []
    timings: list[str] = []
    for k in range(cue_count):
        start_s = k * 4 + 1
        end_s = start_s + 2
        ts = (
            f"{start_s // 3600:02d}:{(start_s % 3600) // 60:02d}:{start_s % 60:02d},000"
            f" --> "
            f"{end_s // 3600:02d}:{(end_s % 3600) // 60:02d}:{end_s % 60:02d},000"
        )
        timings.append(ts)
        blocks.append(f"{k + 1}\n{ts}\nNeo says hello line number {k}.\n")
    path.write_text("\n".join(blocks), encoding="utf-8")
    return timings


def _read_srt_timings_and_texts(path: Path) -> list[tuple[str, str]]:
    raw_blocks = [b for b in path.read_text(encoding="utf-8").strip().split("\n\n") if b.strip()]
    out = []
    for block in raw_blocks:
        lines = block.splitlines()
        out.append((lines[1], "\n".join(lines[2:])))
    return out


async def _setup_env(tmp_path: Path, monkeypatch, proxy_url: str, *, episodes: int, cues: int):
    monkeypatch.chdir(tmp_path)
    db_file = tmp_path / "batch_e2e.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_file}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    reset_setting_store()
    translate.reset_provider_throttles()

    init_secret_box(None, tmp_path / ".secret_key")
    init_db(f"sqlite+aiosqlite:///{db_file}", echo=False)
    await run_migrations()
    init_setting_store()

    async def _skip_audio_sync(*_args, **_kwargs):
        return None

    monkeypatch.setattr(sync, "sample_sync_score", _skip_audio_sync)

    root = tmp_path / "media" / "Show"
    root.mkdir(parents=True)
    file_ids: list[int] = []
    videos: list[Path] = []
    expected_timings: list[list[str]] = []

    db = get_database()
    async with db.session() as session:
        repo = LlmProviderRepository(session)
        await repo.create(
            name="Gemini CLI Proxy",
            provider_type="openai_compat",
            base_url=proxy_url,
            api_key="sk-e2e-proxy",
            default_model="gemini-2.5-flash",
            extra_models=[
                {
                    "id": "gemini-2.5-flash",
                    "context_window": 128000,
                    "max_output_tokens": 8192,
                }
            ],
        )
        library = Library(name="剧集库", kind=MediaKind.TV, root_paths=[str(root)])
        session.add(library)
        await session.flush()
        for ep in range(1, episodes + 1):
            video = root / f"Show.S01E{ep:02d}.mkv"
            video.write_bytes(b"dummy-video")
            srt = root / f"Show.S01E{ep:02d}.eng.srt"
            timings = _write_english_srt(srt, cues)
            row = LibraryFile(
                library_id=library.id,
                file_path=str(video),
                source=FileSource.SCANNED,
                duration_seconds=cues * 4 + 10,
                subtitle_streams=[],
                external_subtitles=[
                    {"filename": srt.name, "format": "srt", "language": "eng"},
                ],
            )
            session.add(row)
            await session.flush()
            assert row.id is not None
            file_ids.append(row.id)
            videos.append(video)
            expected_timings.append(timings)
        await session.commit()

    app = create_app()
    principal = lambda: Principal(kind="admin", name="tester")  # noqa: E731
    app.dependency_overrides[require_login] = principal
    app.dependency_overrides[require_admin] = principal
    return app, file_ids, videos, expected_timings


async def _teardown_env() -> None:
    await jobs.close_job_dispatcher()
    await _runtime_router.aclose()
    await dispose_db()
    translate.reset_provider_throttles()
    reset_setting_store()
    get_settings.cache_clear()


async def test_season_batch_generation_survives_strict_rpm_proxy_without_failures_or_starvation(
    tmp_path: Path, monkeypatch
) -> None:
    """Issue #1282 核心端到端场景：整季 6 集一次性提交至单并发 + RPM 限流反代。"""
    monkeypatch.setattr(translate, "_RATE_LIMIT_MIN_DELAY", 0.02)
    monkeypatch.setattr(translate, "_RATE_LIMIT_MAX_DELAY", 0.25)
    monkeypatch.setattr(translate, "_PACING_MIN_INTERVAL", 0.06)
    monkeypatch.setattr(translate, "_PACING_MAX_INTERVAL", 0.3)
    monkeypatch.setattr(translate, "_CONCURRENCY_RECOVERY_SUCCESSES", 20)

    proxy = _StrictRateLimitProxy(max_in_flight=1, min_spacing=0.05)
    proxy_url = proxy.start()
    try:
        app, file_ids, videos, expected_timings = await _setup_env(
            tmp_path, monkeypatch, proxy_url, episodes=6, cues=150
        )
        # 注册一条常规后台任务，用于验证整季字幕不会占满全局 4 槽、饿死其他任务
        normal_job_finished_at: float | None = None

        async def normal_scan(_ctx, _data):
            nonlocal normal_job_finished_at
            normal_job_finished_at = time.monotonic()
            return {"ok": True}

        monkeypatch.setitem(
            jobs._handlers,
            "test.normal.scan",
            jobs.RegisteredJobHandler(normal_scan, frozenset({1})),
        )

        await jobs.init_job_dispatcher(max_parallel=jobs.DEFAULT_MAX_PARALLEL)
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
            headers={"Accept-Language": "zh-Hans"},
        ) as client:
            # 模拟用户一口气把整季 6 集全部点击生成
            job_ids: list[str] = []
            for fid in file_ids:
                resp = await client.post(
                    f"/api/v1/libraries/files/{fid}/subtitles/generations",
                    json={"target_language": "chs"},
                )
                assert resp.status_code == 202, resp.text
                job_ids.append(resp.json()["data"]["id"])

            # 紧接着提交一条常规后台任务
            async with get_database().session() as session:
                normal_ref = await jobs.create_job(
                    session, job_type="test.normal.scan", input_data={}
                )

            # 常规任务应在字幕尚在进行中时就被空余槽位立即执行完毕
            normal_deadline = time.monotonic() + 5.0
            while time.monotonic() < normal_deadline:
                r = await client.get(f"/api/v1/jobs/{normal_ref.job.id}")
                if r.json()["data"]["status"] == JobStatus.SUCCEEDED.value:
                    break
                await asyncio.sleep(0.05)
            assert normal_job_finished_at is not None

            # 等待整季 6 集全部完成
            deadline = time.monotonic() + 30.0
            final_jobs: dict[str, dict] = {}
            while time.monotonic() < deadline and len(final_jobs) < len(job_ids):
                for jid in job_ids:
                    if jid in final_jobs:
                        continue
                    r = await client.get(f"/api/v1/jobs/{jid}")
                    data = r.json()["data"]
                    if data["status"] in {"succeeded", "failed", "cancelled", "blocked"}:
                        final_jobs[jid] = data
                if len(final_jobs) < len(job_ids):
                    await asyncio.sleep(0.1)

            assert len(final_jobs) == 6, f"仍有任务未完成：{final_jobs}"
            assert all(j["status"] == "succeeded" for j in final_jobs.values()), final_jobs

            # 「需要处理」里的失败任务必须为 0
            failed_resp = await client.get("/api/v1/jobs", params={"status": "failed"})
            assert failed_resp.status_code == 200
            assert failed_resp.json()["data"]["items"] == []

        # 核对磁盘产物：每集 150 条译文与原时间轴逐条对齐，且台账已刷新
        for video, timings in zip(videos, expected_timings, strict=True):
            out = video.with_name(f"{video.stem}.ai-chs.chi.srt")
            assert out.is_file(), f"缺少落盘字幕：{out}"
            cues = _read_srt_timings_and_texts(out)
            assert len(cues) == 150
            assert [ts for ts, _ in cues] == timings
            assert cues[0][1] == "译文0号" and cues[-1][1] == "译文149号"

        # 核对真实发生了限流但系统自动收敛，且没有对任何一条对白重复交付
        assert proxy.rate_limits > 0, "代理应真实触发过 429 以验证自适应收敛"
        duplicates = {k: v for k, v in proxy.delivered_per_film.items() if v > 1}
        assert not duplicates, f"存在重复计费的译文行：{duplicates}"
        assert sum(proxy.delivered_per_film.values()) == 6 * 150
    finally:
        proxy.close()
        await _teardown_env()


async def test_sustained_quota_window_enters_retry_wait_and_resumes_from_checkpoint_e2e(
    tmp_path: Path, monkeypatch
) -> None:
    """长窗口配额限流端到端场景：块内重试耗尽后转 retry_wait，限流解除后自动断点续译成功。"""
    monkeypatch.setattr(translate, "_RATE_LIMIT_MIN_DELAY", 0.01)
    monkeypatch.setattr(translate, "_RATE_LIMIT_MAX_DELAY", 0.02)
    monkeypatch.setattr(translate, "_RATE_LIMIT_MAX_RETRIES", 2)
    monkeypatch.setattr(translate, "_PACING_MIN_INTERVAL", 0.01)
    monkeypatch.setattr(tasks, "_MODEL_RETRY_DELAY_SECONDS", 1)
    monkeypatch.setattr(tasks, "_RATE_LIMIT_RETRY_BASE_SECONDS", 1)
    monkeypatch.setattr(tasks, "_RATE_LIMIT_RETRY_MAX_SECONDS", 2)

    proxy = _StrictRateLimitProxy(max_in_flight=1, min_spacing=0.0)
    proxy.latency = 0.01
    # 放行第 1 个翻译块成功，随后进入持续 429 配额窗口
    proxy.force_429_after_translate_ok = 1
    proxy_url = proxy.start()
    try:
        app, file_ids, videos, expected_timings = await _setup_env(
            tmp_path, monkeypatch, proxy_url, episodes=1, cues=150
        )
        await jobs.init_job_dispatcher(max_parallel=jobs.DEFAULT_MAX_PARALLEL)
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
            headers={"Accept-Language": "zh-Hans"},
        ) as client:
            resp = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations",
                json={"target_language": "chs"},
            )
            assert resp.status_code == 202, resp.text
            job_id = resp.json()["data"]["id"]

            # 等待任务平稳进入 retry_wait（而非落入 failed）
            saw_retry_wait = False
            deadline = time.monotonic() + 10.0
            while time.monotonic() < deadline:
                data = (await client.get(f"/api/v1/jobs/{job_id}")).json()["data"]
                if data["status"] == JobStatus.RETRY_WAIT.value:
                    saw_retry_wait = True
                    assert data["error"]["code"] == "SUBTITLE_MODEL_RATE_LIMITED"
                    break
                assert data["status"] != JobStatus.FAILED.value, f"不应直接失败：{data}"
                await asyncio.sleep(0.05)
            assert saw_retry_wait, "持续限流应转入 retry_wait 等待自动续译"

            # 模拟上游配额窗口恢复，解除持续 429
            proxy.force_429_after_translate_ok = None
            proxy.force_429 = False

            # 等待调度器自动续跑完成
            deadline = time.monotonic() + 15.0
            final = None
            while time.monotonic() < deadline:
                data = (await client.get(f"/api/v1/jobs/{job_id}")).json()["data"]
                if data["status"] in {"succeeded", "failed", "cancelled", "blocked"}:
                    final = data
                    break
                await asyncio.sleep(0.1)

            assert final is not None and final["status"] == "succeeded", final
            assert final["attempt"] >= 2

        out = videos[0].with_name(f"{videos[0].stem}.ai-chs.chi.srt")
        assert out.is_file()
        cues = _read_srt_timings_and_texts(out)
        assert len(cues) == 150
        assert [ts for ts, _ in cues] == expected_timings[0]
        # 第 1 块已落断点，续跑时不能重复交付已完成的对白
        duplicates = {k: v for k, v in proxy.delivered_per_film.items() if v > 1}
        assert not duplicates, f"断点续译重复翻译了已完成块：{duplicates}"
        assert sum(proxy.delivered_per_film.values()) == 150
    finally:
        proxy.close()
        await _teardown_env()


async def test_subtitle_resubmit_success_clears_earlier_same_target_failures_e2e(
    tmp_path: Path, monkeypatch
) -> None:
    """Issue #1331 端到端回归：真实字幕生成路由独立重发成功后，仅同文件同目标更早失败退出待处理。"""
    monkeypatch.setattr(translate, "_RATE_LIMIT_MIN_DELAY", 0.01)
    monkeypatch.setattr(translate, "_RATE_LIMIT_MAX_DELAY", 0.05)
    monkeypatch.setattr(translate, "_PACING_MIN_INTERVAL", 0.01)
    monkeypatch.setattr(translate, "_PACING_MAX_INTERVAL", 0.05)
    monkeypatch.setattr(tasks, "_RATE_LIMIT_RETRY_BASE_SECONDS", 1)
    monkeypatch.setattr(tasks, "_RATE_LIMIT_RETRY_MAX_SECONDS", 1)

    # 让上游失败任务用 1 次尝试即耗尽重试，快速模拟 #1331 中的 JOB_RETRY_EXHAUSTED
    orig_create_job = jobs.create_job

    async def single_attempt_create_job(*args, **kwargs):
        if kwargs.get("job_type") == "subtitle.generate":
            kwargs["max_attempts"] = 1
        return await orig_create_job(*args, **kwargs)

    monkeypatch.setattr(jobs, "create_job", single_attempt_create_job)

    proxy = _StrictRateLimitProxy(max_in_flight=4, min_spacing=0.0)
    proxy.latency = 0.0
    proxy.force_429 = True
    proxy_url = proxy.start()

    async def wait_terminal(client: AsyncClient, job_id: str, timeout: float = 15.0) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = (await client.get(f"/api/v1/jobs/{job_id}")).json()["data"]
            if data["status"] in {"succeeded", "failed", "cancelled", "blocked"}:
                return data
            await asyncio.sleep(0.05)
        raise AssertionError(f"任务 {job_id} 超时未进入终态")

    try:
        app, file_ids, videos, expected_timings = await _setup_env(
            tmp_path, monkeypatch, proxy_url, episodes=2, cues=150
        )
        await jobs.init_job_dispatcher(max_parallel=jobs.DEFAULT_MAX_PARALLEL)
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://testserver",
            headers={"Accept-Language": "zh-Hans"},
        ) as client:
            # 1) 供应商持续 429：file 0 双语失败 2 次，file 0 单语失败 1 次，file 1 双语失败 1 次
            bilingual = {"target_language": "chs", "secondary_language": "eng"}
            monolingual = {"target_language": "chs"}

            r1 = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations", json=bilingual
            )
            assert r1.status_code == 202, r1.text
            fail_f0_bi_1 = await wait_terminal(client, r1.json()["data"]["id"])
            assert fail_f0_bi_1["status"] == "failed"

            r2 = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations", json=bilingual
            )
            assert r2.status_code == 202, r2.text
            fail_f0_bi_2 = await wait_terminal(client, r2.json()["data"]["id"])
            assert fail_f0_bi_2["status"] == "failed"

            r3 = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations", json=monolingual
            )
            assert r3.status_code == 202, r3.text
            fail_f0_mono = await wait_terminal(client, r3.json()["data"]["id"])
            assert fail_f0_mono["status"] == "failed"

            r4 = await client.post(
                f"/api/v1/libraries/files/{file_ids[1]}/subtitles/generations", json=bilingual
            )
            assert r4.status_code == 202, r4.text
            fail_f1_bi = await wait_terminal(client, r4.json()["data"]["id"])
            assert fail_f1_bi["status"] == "failed"

            # 2) 供应商恢复：独立重新发起 file 0 双语（retry_of_job_id=None）并成功落盘
            proxy.force_429 = False
            await asyncio.sleep(0.02)
            r_ok = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations", json=bilingual
            )
            assert r_ok.status_code == 202, r_ok.text
            ok_f0_bi = await wait_terminal(client, r_ok.json()["data"]["id"])
            assert ok_f0_bi["status"] == "succeeded", ok_f0_bi
            assert ok_f0_bi["retry_of_job_id"] is None

            out = videos[0].with_name(f"{videos[0].stem}.ai-bilingual-chs-eng.chi.srt")
            assert out.is_file()
            assert len(_read_srt_timings_and_texts(out)) == len(expected_timings[0])

            # 3) 检查待处理清单：file 0 双语 2 条旧失败已退出；单语与 file 1 双语仍在待处理
            for old_view in (fail_f0_bi_1, fail_f0_bi_2):
                cur = (await client.get(f"/api/v1/jobs/{old_view['id']}")).json()["data"]
                assert cur["status"] == "failed"
                assert cur["error"]["code"] == old_view["error"]["code"]
                assert cur["dismissed_at"] is not None
                assert cur["dismissed_by"] == "system:subtitle-succeeded"
                assert cur["updated_at"] == old_view["updated_at"]
                assert cur["updated_at"] <= ok_f0_bi["updated_at"]

            cur_mono = (await client.get(f"/api/v1/jobs/{fail_f0_mono['id']}")).json()["data"]
            assert cur_mono["status"] == "failed" and cur_mono["dismissed_at"] is None
            cur_f1 = (await client.get(f"/api/v1/jobs/{fail_f1_bi['id']}")).json()["data"]
            assert cur_f1["status"] == "failed" and cur_f1["dismissed_at"] is None

            # 4) 供应商再次 429：成功之后对 file 0 双语新发起并失败，仍应留在「需要处理」
            proxy.force_429 = True
            await asyncio.sleep(0.02)
            r_after = await client.post(
                f"/api/v1/libraries/files/{file_ids[0]}/subtitles/generations", json=bilingual
            )
            assert r_after.status_code == 202, r_after.text
            fail_after = await wait_terminal(client, r_after.json()["data"]["id"])
            assert fail_after["status"] == "failed"
            assert fail_after["dismissed_at"] is None
    finally:
        proxy.close()
        await _teardown_env()
