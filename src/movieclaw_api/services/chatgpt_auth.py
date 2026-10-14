"""电脑上的 loopback 助手接回调，NAS 持有 PKCE 与加密凭据。"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import secrets
import time
from dataclasses import dataclass
from urllib.parse import urlencode, urlparse
from uuid import uuid4

import httpx
from pydantic import Field

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.settings import get_setting_store
from movieclaw_api.settings.base import SettingSchema, register_setting
from movieclaw_db.crypto import get_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.repositories.llm_provider_repo import LlmProviderRepository
from movieclaw_llm.chatgpt import (
    AUTHORIZE_URL,
    ISSUER,
    PLAN_SCOPE,
    RESOURCE,
    SCOPES,
    ChatGPTCredentials,
    account_model_catalog,
    token_request,
    verify_id_token,
)
from movieclaw_llm.exceptions import LlmAuthError
from movieclaw_llm.protocols import build_protocol
from movieclaw_llm.protocols.openai_chatgpt import OpenAIChatGPTProtocol
from movieclaw_net import egress_transport


@register_setting(namespace="llm.chatgpt", title="ChatGPT 授权主机")
class ChatGPTHostSetting(SettingSchema):
    host_id: str = Field(default_factory=lambda: "urn:uuid:" + str(uuid4()))


@dataclass
class PendingSignIn:
    state: str
    nonce: str
    verifier: str
    redirect_uri: str
    host_id: str
    client_id: str
    subject: str | None
    provider_id: int | None
    name: str
    expires_at: float


_pending: dict[str, PendingSignIn] = {}
_pending_lock = asyncio.Lock()


class DatabaseChatGPTTokenStore:
    def __init__(self) -> None:
        self._locks: dict[int, asyncio.Lock] = {}

    def lock(self, provider_id: int) -> asyncio.Lock:
        return self._locks.setdefault(provider_id, asyncio.Lock())

    async def load(self, provider_id: int) -> str:
        async with get_database().session() as session:
            repo = LlmProviderRepository(session)
            row = await repo.get(provider_id)
            if row is None or row.provider_type != "chatgpt":
                raise LlmAuthError("ChatGPT 接入已移除，请重新连接")
            return repo.decrypted_api_key(row)

    async def save(self, provider_id: int, previous: str, updated: str) -> None:
        async with get_database().session() as session:
            repo = LlmProviderRepository(session)
            row = await repo.get(provider_id)
            if row is None or row.provider_type != "chatgpt":
                raise LlmAuthError("ChatGPT 接入已移除，请重新连接")
            if repo.decrypted_api_key(row) != previous:
                raise LlmAuthError("ChatGPT 账号已更新，请重新发起请求")
            row.api_key = get_secret_box().encrypt(updated)
            await session.commit()


token_store = DatabaseChatGPTTokenStore()


async def revoke_credentials(credentials: ChatGPTCredentials) -> bool:
    """清除本地接入前尝试撤销可续期会话，失败时由调用方明确告知用户。"""
    try:
        async with httpx.AsyncClient(transport=egress_transport("llm"), timeout=10) as client:
            discovery = await client.get(ISSUER + "/.well-known/openid-configuration")
            discovery.raise_for_status()
            address = discovery.json().get("revocation_endpoint", "")
            parsed = urlparse(address)
            if (
                parsed.scheme != "https"
                or parsed.hostname != "auth.openai.com"
                or parsed.port not in (None, 443)
            ):
                return False
            response = await client.post(
                address,
                data={
                    "token": credentials.refresh_token,
                    "token_type_hint": "refresh_token",
                    "client_id": credentials.client_id,
                },
            )
            return response.status_code == 200
    except (httpx.HTTPError, ValueError):
        return False


def build_server_protocol(config, preset):
    protocol = build_protocol(config, preset)
    if isinstance(protocol, OpenAIChatGPTProtocol) and config.provider_id is not None:
        protocol.token_store = token_store
    return protocol


async def start_sign_in(session, *, redirect_uri: str, name: str, app_name: str, provider_id=None):
    name = name.strip()
    if not name or "/" in name:
        raise BadRequestException("模型接入名称不能为空或包含斜杠 /")
    try:
        callback = urlparse(redirect_uri)
        port = callback.port
    except ValueError:
        raise BadRequestException("ChatGPT 回调端口无效") from None
    if (
        callback.scheme != "http"
        or callback.hostname != "127.0.0.1"
        or not port
        or callback.path != "/auth/callback"
        or callback.query
        or callback.fragment
        or callback.username
        or callback.password
    ):
        raise BadRequestException(
            "ChatGPT 回调必须使用电脑的 http://127.0.0.1:<端口>/auth/callback"
        )
    repo = LlmProviderRepository(session)
    prior = None
    if provider_id is not None:
        row = await repo.get(provider_id)
        if row is None or row.provider_type != "chatgpt":
            raise NotFoundException("找不到这个 ChatGPT 接入")
        prior = ChatGPTCredentials.parse(repo.decrypted_api_key(row))
        name = row.name
    async with _pending_lock:
        now = time.time()
        for key in [key for key, item in _pending.items() if item.expires_at <= now]:
            _pending.pop(key)
        if len(_pending) >= 32:
            raise BadRequestException("正在等待的 ChatGPT 授权过多，请稍后重试")
        store = get_setting_store()
        host = await store.get(ChatGPTHostSetting)
        await store.set(host)  # 首次生成的主机 ID 在重启后保持不变
        pending = PendingSignIn(
            state=secrets.token_urlsafe(32),
            nonce=secrets.token_urlsafe(32),
            verifier=secrets.token_urlsafe(48),
            redirect_uri=redirect_uri,
            host_id=host.host_id,
            client_id=prior.client_id if prior else "dynamic_agent_client",
            subject=prior.subject if prior else None,
            provider_id=provider_id,
            name=name,
            expires_at=now + 600,
        )
        attempt = secrets.token_urlsafe(32)
        _pending[attempt] = pending
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(pending.verifier.encode()).digest())
        .decode()
        .rstrip("=")
    )
    params = {
        "client_id": pending.client_id,
        "ext_agent_host_id": pending.host_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": SCOPES,
        "resource": RESOURCE,
        "state": pending.state,
        "nonce": pending.nonce,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
    }
    if prior is None:
        params["agent_name_hint"] = app_name
    else:
        if prior.id_token:
            params["id_token_hint"] = prior.id_token
        if prior.email:
            params["login_hint"] = prior.email
    return {
        "attempt_id": attempt,
        "state": pending.state,
        "authorize_url": AUTHORIZE_URL + "?" + urlencode(params),
    }


async def complete_sign_in(
    session, *, attempt_id: str, state: str, code: str, client_id: str | None
):
    async with _pending_lock:
        pending = _pending.get(attempt_id)
        if pending is None or pending.expires_at <= time.time():
            _pending.pop(attempt_id, None)
            raise BadRequestException("ChatGPT 授权已过期，请在电脑重新连接")
        if not secrets.compare_digest(state, pending.state):
            raise BadRequestException("ChatGPT 回调校验失败，请重新连接")
        _pending.pop(attempt_id)  # 一次性消费，失败后不能重放 authorization code
    issued_id = client_id or pending.client_id
    if not issued_id.startswith("oaiapp_") or (
        pending.client_id != "dynamic_agent_client" and issued_id != pending.client_id
    ):
        raise BadRequestException("ChatGPT 返回的客户端身份不匹配，请重新连接")
    data = {}
    try:
        async with httpx.AsyncClient(transport=egress_transport("llm"), timeout=30) as client:
            data = await token_request(
                client,
                {
                    "grant_type": "authorization_code",
                    "client_id": issued_id,
                    "code": code,
                    "code_verifier": pending.verifier,
                    "redirect_uri": pending.redirect_uri,
                    "resource": RESOURCE,
                },
            )
            scopes = str(data.get("scope", "")).split()
            if (
                PLAN_SCOPE not in scopes
                or not data.get("refresh_token")
                or not data.get("id_token")
            ):
                raise LlmAuthError("请在 ChatGPT 授权页面允许使用订阅额度")
            keys = await client.get(ISSUER + "/.well-known/jwks.json")
            keys.raise_for_status()
            claims = verify_id_token(data["id_token"], keys.json(), issued_id, pending.nonce)
            if pending.subject is not None and claims["sub"] != pending.subject:
                raise LlmAuthError("本次登录不是原来的 ChatGPT 账号，请新增接入")
            models_response = await client.get(
                RESOURCE + "/models",
                headers={
                    "Authorization": "Bearer " + data["access_token"],
                },
            )
            models_response.raise_for_status()
            models = [
                m
                for m in models_response.json().get("models", [])
                if m.get("visibility") == "list" and m.get("slug")
            ]
    except (LlmAuthError, httpx.HTTPError, ValueError) as exc:
        await _revoke_rejected_grant(data, issued_id, pending.host_id)
        message = (
            str(exc) if isinstance(exc, LlmAuthError) else "ChatGPT 授权服务暂时不可用，请重新连接"
        )
        raise BadRequestException(message) from None
    if not models:
        await _revoke_rejected_grant(data, issued_id, pending.host_id)
        raise BadRequestException("这个 ChatGPT 账号暂时没有可用模型，请检查订阅或工作区权限")
    credentials = ChatGPTCredentials(
        client_id=issued_id,
        subject=claims["sub"],
        email=claims.get("email", ""),
        ext_agent_host_id=pending.host_id,
        access_token=data["access_token"],
        refresh_token=data["refresh_token"],
        id_token=data["id_token"],
        scopes=scopes,
        expires_at=time.time() + int(data.get("expires_in", 3600)),
    )
    catalog = account_model_catalog(models)
    text_models = [m.id for m in catalog if "text" in m.modalities]
    if not text_models:
        await revoke_credentials(credentials)
        raise BadRequestException("这个 ChatGPT 账号暂时没有可用的文本对话模型")
    # Catalog ordering can change; prefer a known conversational model, preserving
    # the existing choice during reauthorization when it remains available.
    preferred = ["gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-sol"]
    if pending.provider_id is not None:
        row = await LlmProviderRepository(session).get(pending.provider_id)
        if row is not None:
            preferred.insert(0, row.default_model)
    default_model = next((m for m in preferred if m in text_models), text_models[0])
    from movieclaw_api.services.llm_config import LlmConfigService

    service = LlmConfigService(session)
    args = {
        "name": pending.name,
        "provider_type": "chatgpt",
        "base_url": None,
        "api_key": credentials.model_dump_json(),
        "default_model": default_model,
        "extra_models": catalog,
    }
    try:
        if pending.provider_id is not None:
            return await service.update(pending.provider_id, **args)
        repo = LlmProviderRepository(session)
        suffix = 1
        while await repo.get_by_name(args["name"]):
            suffix += 1
            args["name"] = f"{pending.name} {suffix}"
        return await service.create(**args)
    except Exception:
        await revoke_credentials(credentials)
        raise


async def _revoke_rejected_grant(data: dict, client_id: str, host_id: str) -> None:
    if isinstance(data.get("refresh_token"), str) and data["refresh_token"]:
        await revoke_credentials(
            ChatGPTCredentials(
                client_id=client_id,
                subject="",
                ext_agent_host_id=host_id,
                access_token=data.get("access_token", ""),
                refresh_token=data["refresh_token"],
                scopes=[],
                expires_at=0,
            )
        )
