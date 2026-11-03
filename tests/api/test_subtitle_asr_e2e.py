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
