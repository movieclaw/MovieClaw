"""设备授权：「填地址 → 验证连接 → 网页批准」（docs/design/device-auth.md）。

转码器出示一个短配对码，人在已登录的网页（或 App）上核对后批准，令牌只回到发起请求的这个进程：
不抄写密钥、不把管理员密码交给任何程序。令牌逐设备签发、带 ``transcode`` 范围，可在
「设置 → 设备」单独吊销。
"""

from __future__ import annotations

import json
import platform
import time
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from . import __version__

#: 到 NAS 的请求一律直连：系统环境里的 HTTP(S)_PROXY（科学上网的常驻代理最常见）会把内网流量
#: 绕出去，实测把单连接吞吐压到 1.7 MB/s
_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class PairingError(Exception):
    """配对没成功；文案给人看。"""


@dataclass(frozen=True)
class PairingRequest:
    user_code: str
    device_code: str
    verification_uri_complete: str
    interval: float
    expires_in: float


def http_json(
    method: str,
    url: str,
    body: dict[str, Any] | None = None,
    *,
    token: str | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict[str, Any] | None]:
    """发一个 JSON 请求，返回 (HTTP 状态码, 解析后的响应体)。非 2xx 也照常返回，不抛异常。"""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json", "User-Agent": f"MovieClawTranscoder/{__version__}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with _DIRECT.open(request, timeout=timeout) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    try:
        parsed = json.loads(raw.decode("utf-8")) if raw else None
    except ValueError:
        parsed = None
    return status, parsed if isinstance(parsed, dict) else None


def check_server(server: str) -> str | None:
    """验证地址：连得上、而且确实是 MovieClaw。返回 None 表示可用，否则是给人看的原因。"""
    try:
        status, view = http_json("GET", f"{server}/api/v1/health", timeout=8.0)
    except (OSError, ValueError) as exc:
        return f"连不上 {server}：{exc}"
    if status != 200 or not view:
        return f"{server} 没有按预期应答（HTTP {status}），地址对吗？"
    # /health 直接返回 HealthResponse，不套 {"data": …} 信封
    service = str(view.get("service") or "")
    if "movieclaw" not in service.lower():
        return f"{server} 看起来不是 MovieClaw（service={service or '未知'}）"
    return None


def request_pairing(server: str, name: str, installation_id: str) -> PairingRequest:
    status, view = http_json(
        "POST",
        f"{server}/api/v1/auth/device/authorize",
        {
            "client_type": "worker",
            "client_name": name,
            "installation_id": installation_id,
            "platform": f"Windows {platform.version()} · {platform.machine().lower()}",
            "client_version": __version__,
        },
    )
    data = (view or {}).get("data")
    if status != 200 or not isinstance(data, dict):
        raise PairingError(f"发起配对失败（HTTP {status}）：{(view or {}).get('message', '')}")
    return PairingRequest(
        user_code=str(data["user_code"]),
        device_code=str(data["device_code"]),
        verification_uri_complete=str(data["verification_uri_complete"]),
        interval=float(data.get("interval") or 5),
        expires_in=float(data.get("expires_in") or 300),
    )


def wait_for_approval(
    server: str,
    request: PairingRequest,
    *,
    sleep: Callable[[float], None] = time.sleep,
    cancelled: Callable[[], bool] = lambda: False,
) -> str:
    """轮询兑换令牌。202 继续等；429 退避；400（拒绝 / 过期）停止——那要重新发起配对。"""
    deadline = time.monotonic() + request.expires_in
    interval = request.interval
    while time.monotonic() < deadline and not cancelled():
        sleep(interval)
        status, view = http_json(
            "POST", f"{server}/api/v1/auth/device/token", {"device_code": request.device_code}
        )
        data = (view or {}).get("data")
        if status == 200 and isinstance(data, dict) and data.get("token"):
            return str(data["token"])
        if status == 202:
            continue
        if status == 429:
            interval = min(interval * 2, 30.0)
            continue
        raise PairingError(str((view or {}).get("message") or f"配对失败（HTTP {status}）"))
    if cancelled():
        raise PairingError("已取消配对")
    raise PairingError("配对码已过期（5 分钟内没有批准），请重新运行")


def revoke_credential(server: str, token: str) -> bool:
    """断开配对时尽力在服务端注销这枚凭证；服务器连不上返回 False（本机照样清）。"""
    try:
        status, _ = http_json("DELETE", f"{server}/api/v1/auth/devices/current", token=token)
    except (OSError, ValueError):
        return False
    return status in (200, 204)
