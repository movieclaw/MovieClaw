"""本机 ffmpeg 的凭据隔离转发，复用播放器的 Range 转发路径。"""

from __future__ import annotations

import json

from cryptography.fernet import Fernet, InvalidToken
from fastapi import APIRouter, HTTPException, Request

from movieclaw_playback.streaming import RemoteRelayResponse

router = APIRouter()
# 进程内能力票据：URL 不暴露上游凭据，也无需为长时间播放保留取链缓存。
_cipher = Fernet(Fernet.generate_key())


def relay_url(base: str, url: str, headers: dict[str, str]) -> str:
    ticket = _cipher.encrypt(json.dumps([url, headers]).encode()).decode()
    return f"{base}/internal/ffmpeg-stream/{ticket}"


@router.api_route(
    "/internal/ffmpeg-stream/{ticket}", methods=["GET", "HEAD"], include_in_schema=False
)
async def ffmpeg_stream(ticket: str, request: Request):
    # 仅供本机使用，并且必须持有此进程签发的加密票据。
    if request.client is None or request.client.host not in {"127.0.0.1", "::1"}:
        raise HTTPException(status_code=403)
    try:
        url, headers = json.loads(_cipher.decrypt(ticket.encode()))
    except InvalidToken as exc:
        raise HTTPException(status_code=404) from exc
    return RemoteRelayResponse(
        url, range_header=request.headers.get("range"), upstream_headers=headers
    )
