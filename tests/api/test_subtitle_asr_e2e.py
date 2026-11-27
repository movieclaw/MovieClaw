"""稀疏对白：真实 API、扫描、持久化任务、ffmpeg 与外挂；ASR/LLM 用确定性替身。"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time

import pytest

from movieclaw_api.services.subtitle_gen import asr, extract
from movieclaw_llm import ChatResponse
from movieclaw_llm.protocols import PROTOCOLS

from . import test_llm

client = test_llm.client  # 复用隔离库与完整 lifespan


@pytest.fixture(autouse=True)
def disable_scheduler(monkeypatch):
    monkeypatch.setenv("SCHEDULER_ENABLED", "0")


class _SubtitleProtocol(test_llm._FakeProtocol):
    async def chat(self, request, model_id):
        system = request.messages[0].content
        user = request.messages[-1].content
        if "翻译下列对白：\n" in user:
            entries = json.loads(user.split("翻译下列对白：\n", 1)[1])
            bilingual = "双语格式" in system
            content = {
                "items": [
                    {"i": entry["i"], "t": f"你好\n{entry['s']}" if bilingual else "你好"}
                    for entry in entries
                ]
            }
        elif "找出其中反复出现的人名" in user:
            content = {"items": []}
        else:
            return ChatResponse(content="pong", finish_reason="stop")
        return ChatResponse(content=json.dumps(content), finish_reason="stop")


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要 ffmpeg")
def test_sparse_asr_bilingual_generation_and_reuse_through_api(client, tmp_path, monkeypatch):
    http, _db_file = client
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _SubtitleProtocol)
    monkeypatch.setattr(extract, "cache_dir", lambda: tmp_path / "cache")
    worker = tmp_path / "sparse_worker.py"
    counter = tmp_path / "worker-runs.txt"
    worker.write_text(
        "import json, sys, wave\n"
        "params = json.loads(sys.stdin.readline())\n"
        f"with open({str(counter)!r}, 'a') as runs: runs.write('run\\n')\n"
        "with wave.open(params['wav']) as audio:\n"
        "    assert audio.getframerate() == 16000 and audio.getnchannels() == 1\n"
        "    assert audio.getnframes() / 16000 >= 320\n"
        "for i in range(41):\n"
        "    print(json.dumps({'type': 'segment', 'start_ms': i * 1000 + 1000,\n"
        "        'end_ms': i * 1000 + 1800, 'text': 'Hello.',\n"
        "        'tokens': ['Hello.'], 'timestamps': [0.1]}), flush=True)\n"
        "print(json.dumps({'type': 'progress', 'position': 320.1}), flush=True)\n"
        "print(json.dumps({'type': 'done', 'language': 'en', 'speech_seconds': 32.8}))\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(asr, "_WORKER", worker)
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, tmp_path, True))
    root = tmp_path / "media"
    root.mkdir()
    video = root / "Sparse.mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=160x90:r=1:d=320",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=16000",
            "-af",
            "volume=0:enable='lt(t,1)+gte(t,42)'",
            "-t",
            "320",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "aac",
            "-metadata:s:a:0",
            "language=eng",
            str(video),
        ],
        check=True,
        timeout=60,
    )
    # 扫描对刚写入的文件有稳定期；测试素材已经完整落盘。
    os.utime(video, (time.time() - 3600,) * 2)
    provider = http.post(
        "/api/v1/llm/providers",
        json={
            "name": "Subtitle fixture",
            "provider_type": "openai_compat",
            "base_url": "http://fixture.invalid/v1",
            "api_key": "test-only",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert provider.status_code == 200, provider.text
    library = http.post(
        "/api/v1/libraries",
        json={
            "name": "Sparse dialogue",
            "kind": "video",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    assert library.status_code == 200, library.text
    library_id = library.json()["data"]["id"]

    def wait_for(read, ready):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            value = read()
            if ready(value):
                return value
            time.sleep(0.1)
        pytest.fail(f"等待超时：{value}")

    items = wait_for(lambda: http.get(f"/api/v1/libraries/{library_id}/items").json()["data"], bool)
    detail = http.get(f"/api/v1/libraries/{library_id}/items/{items[0]['media_item_id']}").json()[
        "data"
    ]
    file_id = detail["files"][0]["id"]
    endpoint = f"/api/v1/libraries/files/{file_id}/subtitles"
    for target, secondary, source_key in (
        ("chs", "eng", "audio:0"),
        ("cht", None, "audio:0"),
        ("chs", None, "external:Sparse.asr.eng.srt"),
    ):
        params = {"target_language": target, "source_candidate_key": source_key}
        if secondary:
            params["secondary_language"] = secondary
        response = http.get(f"{endpoint}/generation-preview", params=params)
        assert response.status_code == 200, response.text
        preview = response.json()["data"]
        assert preview["blocker"] is None, preview
        if counter.exists():
            assert preview["event_count"] == 41
        started = http.post(f"{endpoint}/generations", json=params)
        assert started.status_code == 202, started.text
        job_id = started.json()["data"]["id"]
        job = wait_for(
            lambda job_id=job_id: http.get(f"/api/v1/jobs/{job_id}").json()["data"],
            lambda row: row["status"] in ("succeeded", "failed", "blocked"),
        )
        assert job["status"] == "succeeded", job.get("error")
        result = job["result"]
        output = video.parent / result["filename"]
        written = output.read_text(encoding="utf-8")
        events = extract.parse_events(written, str(output))
        assert len(events) == 41
        assert [(start, end) for start, end, _text in events] == [
            (i * 1000 + 1000, i * 1000 + 1800) for i in range(41)
        ]
        if secondary:
            assert written.count("\n你好\nHello.\n") == 41
    assert counter.read_text() == "run\n", "复用音轨结果及 ASR 外挂均不应重新识别"
    assert (root / "Sparse.asr.eng.srt").read_text().count("-->") == 41


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要 ffmpeg")
def test_synthetic_placeholder_subtitles_preview_and_submit_through_api(
    client, tmp_path, monkeypatch
):
    """#1329：合成空占位 SRT 轨验证预检/提交，区分错误 PGS 提示与既有音轨兜底约定。"""
    import asyncio

    from sqlmodel import select

    from movieclaw_api.services import media_extract
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFile

    http, _db_file = client
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _SubtitleProtocol)
    monkeypatch.setattr(extract, "cache_dir", lambda: tmp_path / "cache")
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "playback-subs")
    worker = tmp_path / "placeholder_asr_worker.py"
    worker.write_text(
        "import json, sys\n"
        "json.loads(sys.stdin.readline())\n"
        "for i in range(5):\n"
        "    print(json.dumps({'type': 'segment', 'start_ms': i * 1000 + 500,\n"
        "        'end_ms': i * 1000 + 1300, 'text': 'Hello.',\n"
        "        'tokens': ['Hello.'], 'timestamps': [0.1]}), flush=True)\n"
        "print(json.dumps({'type': 'done', 'language': 'en', 'speech_seconds': 4.0}))\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(asr, "_WORKER", worker)
    monkeypatch.setattr(asr, "capability", lambda: asr.Capability(True, None, tmp_path, True))

    root = tmp_path / "media"
    root.mkdir()
    srt_dir = tmp_path / "placeholder-srts"
    srt_dir.mkdir()
    video = root / "PlaceholderSubs.mkv"
    langs = ("eng", "eng", "fre", "ger", "spa")
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=black:s=160x90:r=1:d=20",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:sample_rate=16000:duration=20",
    ]
    for idx, _lang in enumerate(langs):
        srt = srt_dir / f"track_{idx}.srt"
        srt.write_text("1\n00:00:07,793 --> 00:00:08,126\n\u200b\n", encoding="utf-8")
        cmd.extend(["-i", str(srt)])
    cmd.extend(["-map", "0:v:0", "-map", "1:a:0"])
    for idx in range(len(langs)):
        cmd.extend(["-map", f"{idx + 2}:0"])
    cmd.extend(
        [
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "aac",
            "-metadata:s:a:0",
            "language=eng",
            "-c:s",
            "srt",
        ]
    )
    for idx, lang in enumerate(langs):
        cmd.extend([f"-metadata:s:s:{idx}", f"language={lang}"])
    cmd.append(str(video))
    subprocess.run(cmd, check=True, timeout=60)
    os.utime(video, (time.time() - 3600,) * 2)

    provider = http.post(
        "/api/v1/llm/providers",
        json={
            "name": "Subtitle fixture",
            "provider_type": "openai_compat",
            "base_url": "http://fixture.invalid/v1",
            "api_key": "test-only",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert provider.status_code == 200, provider.text
    library = http.post(
        "/api/v1/libraries",
        json={
            "name": "Placeholder subtitles",
            "kind": "video",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    assert library.status_code == 200, library.text
    library_id = library.json()["data"]["id"]

    def wait_for(read, ready):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            value = read()
            if ready(value):
                return value
            time.sleep(0.1)
        pytest.fail(f"等待超时：{value}")

    items = wait_for(lambda: http.get(f"/api/v1/libraries/{library_id}/items").json()["data"], bool)
    detail = http.get(f"/api/v1/libraries/{library_id}/items/{items[0]['media_item_id']}").json()[
        "data"
    ]
    file_id = detail["files"][0]["id"]
    endpoint = f"/api/v1/libraries/files/{file_id}/subtitles"

    # 复现步骤 2：先触发一次内封字幕抽取（与播放器预览共用缓存）
    async def _extract_cached() -> None:
        async with get_database().session() as session:
            row = (
                await session.execute(select(LibraryFile).where(LibraryFile.id == file_id))
            ).scalar_one()
            track = await media_extract.extract_track_async(row, 0)
            assert track is not None

    asyncio.run(_extract_cached())

    # 1) 不指定来源：保留既有产品约定（不自动切音轨），预检与提交都给出 unusable_text 真实原因
    base_params = {"target_language": "chs", "secondary_language": "eng"}
    auto_pv = http.get(f"{endpoint}/generation-preview", params=base_params)
    assert auto_pv.status_code == 200, auto_pv.text
    auto_data = auto_pv.json()["data"]
    assert auto_data["chosen_key"] is None
    assert auto_data["selected_source_key"] == "embedded:0"
    assert auto_data["blocker"]["code"] == "unusable_text"
    assert all(c["kind"] != "audio" for c in auto_data["candidates"])

    auto_sub = http.post(f"{endpoint}/generations", json=base_params)
    assert auto_sub.status_code == 400, auto_sub.text
    assert auto_sub.json()["message_key"] == "library.subtitlePreflight.incompleteCandidate"

    # 2) 指定空文本轨 embedded:0 / embedded:1：提交应返回真实残缺原因，绝不误报 pgsChanged
    for key, track_label in (("embedded:0", "内封轨 0"), ("embedded:1", "内封轨 1")):
        params = {**base_params, "source_candidate_key": key}
        pv = http.get(f"{endpoint}/generation-preview", params=params)
        assert pv.status_code == 200, pv.text
        assert pv.json()["data"]["blocker"]["code"] == "unusable_text"

        sub = http.post(f"{endpoint}/generations", json=params)
        assert sub.status_code == 400, sub.text
        err = sub.json()
        assert err["message_key"] == "library.subtitlePreflight.incompleteCandidate", err
        assert track_label in err["message"]
        assert "PGS" not in err["message"]

    # 3) 显式确认 PGS 转换但指定轨不是 PGS 时，仍返回 pgsChanged
    pgs_sub = http.post(
        f"{endpoint}/generations",
        json={**base_params, "source_candidate_key": "embedded:0", "convert_pgs": True},
    )
    assert pgs_sub.status_code == 400, pgs_sub.text
    assert pgs_sub.json()["message_key"] == "errors.subtitles.pgsChanged"

    # 4) 显式指定 audio:0：既有音轨兜底入口在预检与提交均正常跑通
    audio_params = {**base_params, "source_candidate_key": "audio:0"}
    audio_pv = http.get(f"{endpoint}/generation-preview", params=audio_params)
    assert audio_pv.status_code == 200, audio_pv.text
    assert audio_pv.json()["data"]["chosen_key"] == "audio:0"
    assert audio_pv.json()["data"]["blocker"] is None

    audio_sub = http.post(f"{endpoint}/generations", json=audio_params)
    assert audio_sub.status_code == 202, audio_sub.text
    job_id = audio_sub.json()["data"]["id"]
    job = wait_for(
        lambda: http.get(f"/api/v1/jobs/{job_id}").json()["data"],
        lambda row: row["status"] in ("succeeded", "failed", "blocked"),
    )
    assert job["status"] == "succeeded", job.get("error")


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="需要 ffmpeg")
def test_synthetic_offloaded_video_preflight_matches_submit_contract_through_api(
    client, tmp_path, monkeypatch
):
    """#1341/#1325：合成媒体 + 隔离库端到端复现本地腾空后的预检/提交契约一致及仍可读对照。"""
    from pathlib import Path
    from types import SimpleNamespace

    from sqlmodel import select

    from movieclaw_api.services import media_extract
    from movieclaw_api.services.drives import gateway, release, sources
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import (
        DriveAccount,
        LibraryCloudFolder,
        LibraryFile,
        LibraryFileFingerprint,
        LibraryFileReplica,
    )
    from movieclaw_db.models.base import utcnow

    http, _db_file = client
    monkeypatch.setitem(PROTOCOLS, "openai_chat", _SubtitleProtocol)
    monkeypatch.setattr(extract, "cache_dir", lambda: tmp_path / "cache")
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "playback-subs")

    root = tmp_path / "cloud-staging"
    offload_dir = root / "Offloaded Film (2024)"
    readable_dir = root / "Readable Film (2024)"
    offload_dir.mkdir(parents=True)
    readable_dir.mkdir(parents=True)

    srt_content = "\n".join(
        f"{i + 1}\n00:{(i * 4 + 1) // 60:02d}:{(i * 4 + 1) % 60:02d},000 --> "
        f"00:{(i * 4 + 3) // 60:02d}:{(i * 4 + 3) % 60:02d},000\n"
        f"Hello synthetic line {i + 1}.\n"
        for i in range(60)
    )
    src_srt = tmp_path / "eng.srt"
    src_srt.write_text(srt_content, encoding="utf-8")

    offload_video = offload_dir / "Offloaded Film (2024).mkv"
    readable_video = readable_dir / "Readable Film (2024).mkv"
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=160x90:r=1:d=260",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=16000:duration=260",
            "-i",
            str(src_srt),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-map",
            "2:0",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "aac",
            "-metadata:s:a:0",
            "language=eng",
            "-c:s",
            "srt",
            "-metadata:s:s:0",
            "language=eng",
            str(offload_video),
        ],
        check=True,
        timeout=60,
    )
    shutil.copy2(offload_video, readable_video)
    for media in (offload_video, readable_video):
        os.utime(media, (time.time() - 3600,) * 2)

    provider = http.post(
        "/api/v1/llm/providers",
        json={
            "name": "Subtitle offload fixture",
            "provider_type": "openai_compat",
            "base_url": "http://fixture.invalid/v1",
            "api_key": "test-only",
            "default_model": "fixture-model",
            "extra_models": [
                {"id": "fixture-model", "context_window": 32768, "max_output_tokens": 8192}
            ],
        },
    )
    assert provider.status_code == 200, provider.text

    library = http.post(
        "/api/v1/libraries",
        json={
            "name": "Offload subtitle E2E",
            "kind": "video",
            "root_paths": [str(root)],
            "realtime_watch": False,
        },
    )
    assert library.status_code == 200, library.text
    library_id = library.json()["data"]["id"]

    def wait_for(read, ready):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            value = read()
            if ready(value):
                return value
            time.sleep(0.1)
        pytest.fail(f"等待超时：{value}")

    items = wait_for(
        lambda: http.get(f"/api/v1/libraries/{library_id}/items").json()["data"],
        lambda rows: len(rows) == 2,
    )
    file_ids: dict[str, int] = {}
    for item in items:
        detail = http.get(
            f"/api/v1/libraries/{library_id}/items/{item['media_item_id']}"
        ).json()["data"]
        for f in detail["files"]:
            file_ids[Path(f["file_path"]).name] = f["id"]

    offload_id = file_ids[offload_video.name]
    readable_id = file_ids[readable_video.name]
    offload_ep = f"/api/v1/libraries/files/{offload_id}/subtitles"
    readable_ep = f"/api/v1/libraries/files/{readable_id}/subtitles"

    # 1) 腾空前（仍可读基线）：待腾空文件预检选中 embedded:0
    before_pv = http.get(f"{offload_ep}/generation-preview", params={"target_language": "chs"})
    assert before_pv.status_code == 200, before_pv.text
    before_data = before_pv.json()["data"]
    assert before_data["chosen_key"] == "embedded:0"
    assert before_data["blocker"] is None
    assert before_data["reference_notice"]

    # 2) 为待腾空文件登记已核验网盘副本并走真实 release.try_release 腾空本地
    offload_stat = offload_video.stat()

    async def _attach_verified_replica() -> None:
        async with get_database().session() as session:
            account = DriveAccount(
                backend="fake-e2e",
                name="Fake Cloud",
                remote_user_id="u-e2e",
                login_method="cookie",
                status="ok",
                credentials="{}",
            )
            session.add(account)
            await session.flush()
            session.add(
                LibraryCloudFolder(
                    library_id=library_id,
                    account_id=account.id,
                    remote_dir_id="dir-e2e",
                    display_path="/Videos",
                    local_dir=str(root / ".cloud"),
                    is_primary=True,
                )
            )
            row = (
                await session.execute(select(LibraryFile).where(LibraryFile.id == offload_id))
            ).scalar_one()
            row.probe_version = row.probe_version or 2
            session.add(row)
            session.add(
                LibraryFileFingerprint(
                    library_file_id=offload_id,
                    size_bytes=offload_stat.st_size,
                    file_mtime_ns=offload_stat.st_mtime_ns,
                    sha1="0" * 40,
                )
            )
            session.add(
                LibraryFileReplica(
                    library_file_id=offload_id,
                    account_id=account.id,
                    remote_id="remote-offload-1",
                    origin="uploaded",
                    state="verified",
                    size_bytes=offload_stat.st_size,
                    verified_at=utcnow(),
                )
            )
            await session.commit()

    async def _fake_stat(_account_id, method, **_kwargs):  # noqa: ANN001
        assert method == "stat"
        return SimpleNamespace(
            remote_id="remote-offload-1",
            name=offload_video.name,
            size=offload_stat.st_size,
        )

    monkeypatch.setattr(gateway, "call", _fake_stat)

    async def _release_and_bind() -> str | None:
        await _attach_verified_replica()
        sources.bind()
        return await release.try_release(offload_id)

    try:
        assert http.portal.call(_release_and_bind) is None
        assert not offload_video.exists()
        assert sources.cloud_file(str(offload_video)) is not None

        # 3) 原场景（本地腾空后，未缓存内封）：预检与提交一致阻断，且双语种文案与提交一致
        for locale, expected_substr in (
            ("zh-Hans", "参考字幕暂时无法读取"),
            ("en", "cannot be read"),
        ):
            pv = http.get(
                f"{offload_ep}/generation-preview",
                params={"target_language": "chs"},
                headers={"Accept-Language": locale},
            )
            assert pv.status_code == 200, pv.text
            pv_data = pv.json()["data"]
            assert pv_data["chosen_key"] is None
            assert pv_data["selected_source_key"] == "embedded:0"
            assert pv_data["reference_notice"] is None
            assert pv_data["estimated_tokens"] == 0
            assert pv_data["blocker"]["code"] == "unusable_text"
            assert expected_substr in pv_data["blocker"]["message"]
            assert all(c["kind"] != "audio" for c in pv_data["candidates"])

        sub = http.post(f"{offload_ep}/generations", json={"target_language": "chs"})
        assert sub.status_code == 400, sub.text
        assert sub.json()["message_key"] == "errors.subtitles.referenceUnreadable"

        # 4) 腾空前若已有抽轨缓存：云端指纹可命中缓存，但预检仍与提交契约一致阻断
        cache_srt = media_extract.cache_dir() / f"{offload_id}.s0.srt"
        cache_srt.parent.mkdir(parents=True, exist_ok=True)
        cache_srt.write_text(srt_content, encoding="utf-8")
        cached_pv = http.get(f"{offload_ep}/generation-preview", params={"target_language": "chs"})
        assert cached_pv.status_code == 200, cached_pv.text
        assert cached_pv.json()["data"]["chosen_key"] is None
        assert cached_pv.json()["data"]["blocker"]["code"] == "unusable_text"
        cached_sub = http.post(f"{offload_ep}/generations", json={"target_language": "chs"})
        assert cached_sub.status_code == 400
        assert cached_sub.json()["message_key"] == "errors.subtitles.referenceUnreadable"

        # 5) 腾空文件同目录存在可读外挂字幕：默认不自动回退，显式选外挂可预检并通过提交完成
        sidecar = offload_video.with_name(f"{offload_video.stem}.eng.srt")
        sidecar.parent.mkdir(parents=True, exist_ok=True)
        sidecar.write_text(srt_content, encoding="utf-8")

        async def _refresh_sidecars() -> None:
            from movieclaw_api.services.subtitle_gen import tasks as gen_tasks

            await gen_tasks._refresh_subtitle_inventory(get_database(), offload_id)

        http.portal.call(_refresh_sidecars)
        default_with_ext = http.get(
            f"{offload_ep}/generation-preview", params={"target_language": "chs"}
        )
        assert default_with_ext.status_code == 200
        assert default_with_ext.json()["data"]["selected_source_key"] == "embedded:0"
        assert default_with_ext.json()["data"]["chosen_key"] is None
        assert default_with_ext.json()["data"]["blocker"]["code"] == "unusable_text"

        ext_key = f"external:{sidecar.name}"
        ext_pv = http.get(
            f"{offload_ep}/generation-preview",
            params={"target_language": "chs", "source_candidate_key": ext_key},
        )
        assert ext_pv.status_code == 200, ext_pv.text
        assert ext_pv.json()["data"]["chosen_key"] == ext_key
        assert ext_pv.json()["data"]["blocker"] is None
        ext_sub = http.post(
            f"{offload_ep}/generations",
            json={"target_language": "chs", "source_candidate_key": ext_key},
        )
        assert ext_sub.status_code == 202, ext_sub.text
        ext_job_id = ext_sub.json()["data"]["id"]
        ext_job = wait_for(
            lambda: http.get(f"/api/v1/jobs/{ext_job_id}").json()["data"],
            lambda row: row["status"] in ("succeeded", "failed", "blocked"),
        )
        assert ext_job["status"] == "succeeded", ext_job.get("error")

        # 6) 仍可读对照（本地文件未腾空）：预检选中内封轨、提交 202 并端到端完成生成
        ctrl_pv = http.get(f"{readable_ep}/generation-preview", params={"target_language": "chs"})
        assert ctrl_pv.status_code == 200, ctrl_pv.text
        ctrl_data = ctrl_pv.json()["data"]
        assert ctrl_data["chosen_key"] == "embedded:0"
        assert ctrl_data["blocker"] is None
        assert ctrl_data["reference_notice"]

        ctrl_sub = http.post(f"{readable_ep}/generations", json={"target_language": "chs"})
        assert ctrl_sub.status_code == 202, ctrl_sub.text
        ctrl_job_id = ctrl_sub.json()["data"]["id"]
        ctrl_job = wait_for(
            lambda: http.get(f"/api/v1/jobs/{ctrl_job_id}").json()["data"],
            lambda row: row["status"] in ("succeeded", "failed", "blocked"),
        )
        assert ctrl_job["status"] == "succeeded", ctrl_job.get("error")
        out_srt = readable_video.parent / ctrl_job["result"]["filename"]
        assert out_srt.is_file() and out_srt.read_text(encoding="utf-8").count("-->") == 60
    finally:
        sources.unbind()
        sources.reset_state()
