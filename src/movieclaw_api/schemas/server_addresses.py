"""访问地址簿的请求/响应模型（docs/design/server-addresses.md §3.2）。"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import Field

from movieclaw_api.schemas.base import BaseModel


class ServerAddressItem(BaseModel):
    url: str = Field(description="协议 + 主机 + 端口，如 http://192.168.1.10:3300")
    kind: Literal["lan", "wan"] = Field(description="lan = 内网（在家用），wan = 外网（出门用）")
    source: Literal["learned", "configured", "manual"] = Field(
        description="learned = 有人用过自动记下的；configured = 外部访问地址等配置项；"
        "manual = 管理员手动加的"
    )
    last_seen: datetime | None = Field(default=None, description="最近一次有人经它访问")


class ServerAddressesView(BaseModel):
    instance_id: str = Field(description="这台服务器的实例号（与 /health 的 instance_id 相同）")
    host_key: str = Field(
        description="主机公钥（base64url 的 32 字节 Ed25519 公钥）：验 /health?nonce= 的 proof"
    )
    addresses: list[ServerAddressItem] = Field(description="内网在前，各自按最近使用排")
    lan_subnets: list[str] = Field(
        description="内网 IPv4 地址所在的 /24：客户端不发请求就能判断是否在这个网段"
    )


class ServerAddressPayload(BaseModel):
    url: str = Field(description="要加的地址，http:// 或 https:// 开头")
    kind: Literal["lan", "wan"] | None = Field(
        default=None, description="内网 / 外网；不填按地址自动判断"
    )


class ServerAddressRemovePayload(BaseModel):
    url: str = Field(description="要删的地址")
