"""官方 Sign in with ChatGPT 公共客户端契约；不使用 ChatGPT 私有端点。"""

from __future__ import annotations

import base64
import json
import time
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from pydantic import BaseModel, Field, ValidationError

from movieclaw_llm.exceptions import LlmAuthError
from movieclaw_llm.models import ModelInfo, ThinkingControl

ISSUER = "https://auth.openai.com"
AUTHORIZE_URL = ISSUER + "/api/accounts/authorize"
TOKEN_URL = ISSUER + "/api/accounts/oauth/token"
RESOURCE = "https://api.openai.com/v1"
PLAN_SCOPE = "chatgpt.tokens.use.direct"
SCOPES = "openid profile email offline_access resource.invoke " + PLAN_SCOPE


def account_model_catalog(rows: list[dict]) -> list[ModelInfo]:
    """Use account-reported capabilities, with documented presets only as a fallback."""
    from movieclaw_llm.providers import get_preset

    known = {m.id: m for m in get_preset("openai").models}
    catalog = []
    for row in rows:
        if (
            row.get("visibility") != "list"
            or not isinstance(row.get("slug"), str)
            or not row["slug"]
        ):
            continue
        model = known.get(row["slug"]) or ModelInfo(
            id=row["slug"],
            context_window=32768,
            max_output_tokens=8192,
            supports_tools=True,
            supports_parallel_tool_calls=True,
        )
        changes = {}
        for field in ("context_window", "max_output_tokens"):
            if isinstance(row.get(field), int) and row[field] > 0:
                changes[field] = row[field]
        if "context_window" in changes and model.max_input_tokens:
            changes["max_input_tokens"] = min(model.max_input_tokens, changes["context_window"])
        if isinstance(row.get("input_modalities"), list):
            changes["modalities"] = [m for m in row["input_modalities"] if m in ("text", "image")]
        if isinstance(row.get("supports_parallel_tool_calls"), bool):
            changes["supports_parallel_tool_calls"] = row["supports_parallel_tool_calls"]
        if isinstance(row.get("supported_reasoning_levels"), list):
            levels = [
                r.get("effort") if isinstance(r, dict) else r
                for r in row["supported_reasoning_levels"]
            ]
            levels = [level for level in levels if isinstance(level, str)]
            # Codex's "ultra" includes agent orchestration; it is not a public Responses effort.
            changes["thinking_control"] = ThinkingControl(
                kind="effort",
                levels=levels,
                supports_off="none" in levels,
            )
        catalog.append(model.model_copy(update=changes))
    return catalog


def restore_account_model_controls(models: list[ModelInfo]) -> list[ModelInfo]:
    """Repair legacy menus without changing account membership or explicit controls."""
    from movieclaw_llm.providers import get_preset

    known = {m.id: m for m in get_preset("openai").models}
    return [
        m.model_copy(update={"thinking_control": known[m.id].thinking_control})
        if m.thinking_control is None and m.id in known
        else m
        for m in models
    ]


class ChatGPTCredentials(BaseModel):
    """作为现有供应商密钥的加密内容保存，绝不通过供应商视图返回。"""

    client_id: str
    subject: str
    email: str = ""
    ext_agent_host_id: str
    access_token: str = Field(repr=False)
    refresh_token: str = Field(repr=False)
    id_token: str = Field(default="", repr=False)
    scopes: list[str]
    expires_at: float

    @classmethod
    def parse(cls, value: str) -> ChatGPTCredentials:
        try:
            result = cls.model_validate_json(value)
        except (ValidationError, ValueError):
            raise LlmAuthError("ChatGPT 授权无效，请通过电脑重新连接") from None
        if (
            not result.client_id.startswith("oaiapp_")
            or PLAN_SCOPE not in result.scopes
            or not result.subject
            or not result.refresh_token
            or not result.access_token
        ):
            raise LlmAuthError("尚未授权使用 ChatGPT 订阅，请重新连接并允许使用订阅")
        return result


def _decode(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verify_id_token(token: str, jwks: dict, client_id: str, nonce: str) -> dict:
    """校验固定发行者、签名、audience、时效及本次 nonce；拒绝算法降级。"""
    try:
        header64, payload64, signature64 = token.split(".")
        header = json.loads(_decode(header64))
        claims = json.loads(_decode(payload64))
        if header.get("alg") != "RS256":
            raise ValueError("algorithm")
        key = next(k for k in jwks["keys"] if k.get("kid") == header.get("kid"))
        if key.get("kty") != "RSA" or key.get("use", "sig") != "sig":
            raise ValueError("key")
        public_key = rsa.RSAPublicNumbers(
            int.from_bytes(_decode(key["e"]), "big"),
            int.from_bytes(_decode(key["n"]), "big"),
        ).public_key()
        public_key.verify(
            _decode(signature64),
            f"{header64}.{payload64}".encode(),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        audience = claims.get("aud")
        audiences = audience if isinstance(audience, list) else [audience]
        if (
            claims.get("iss") != ISSUER
            or client_id not in audiences
            or claims.get("nonce") != nonce
            or float(claims["exp"]) <= time.time() - 5
            or float(claims["iat"]) > time.time() + 5
            or not isinstance(claims.get("sub"), str)
            or not claims["sub"]
        ):
            raise ValueError("claims")
        return claims
    except Exception as exc:  # noqa: BLE001 -- 不把令牌或第三方响应放入诊断
        raise LlmAuthError("无法验证 ChatGPT 登录身份，请重新连接") from exc


async def token_request(client: httpx.AsyncClient, form: dict[str, str]) -> dict[str, Any]:
    try:
        response = await client.post(TOKEN_URL, data=form)
        response.raise_for_status()
        data = response.json()
        if not isinstance(data, dict) or not data.get("access_token"):
            raise ValueError("missing access token")
        return data
    except (httpx.HTTPError, ValueError) as exc:
        raise LlmAuthError("ChatGPT 授权已失效或暂时无法续期，请重试或重新连接") from exc


async def refresh_credentials(
    client: httpx.AsyncClient,
    credentials: ChatGPTCredentials,
) -> ChatGPTCredentials:
    data = await token_request(
        client,
        {
            "grant_type": "refresh_token",
            "client_id": credentials.client_id,
            "refresh_token": credentials.refresh_token,
            "resource": RESOURCE,
        },
    )
    scopes = data.get("scope", " ".join(credentials.scopes)).split()
    if PLAN_SCOPE not in scopes:
        raise LlmAuthError("ChatGPT 订阅授权已撤销，请重新连接")
    return credentials.model_copy(
        update={
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token") or credentials.refresh_token,
            "id_token": data.get("id_token") or credentials.id_token,
            "scopes": scopes,
            "expires_at": time.time() + int(data.get("expires_in", 3600)),
        }
    )
