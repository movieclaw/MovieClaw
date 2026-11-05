"""插件的网络出口（``movieclaw_sdk.net``，docs/design/plugin-channels.md §7）。

进程外插件读不到主程序的代理设置，向宿主询问；代理地址可能带账号密码，宿主只回答插件自己的服务名
（条目 id 的最后一段），问别的服务一律直连。
"""

from __future__ import annotations

import datetime
import ssl
import sys
import textwrap
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address
from pathlib import Path

import httpx
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_sdk import net

PLUGIN = """
from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_ROUTES
from movieclaw_sdk import net, plugin


@plugin("acme.relay", title="出口插件", inject=(PLUGIN_ROUTES,))
async def apply(ctx) -> None:
    router = APIRouter()

    @router.get("/proxy", operation_id="plugins.acme.relay.proxy")
    async def proxy() -> dict:
        return {"own": await net.proxy_url("relay"), "other": await net.proxy_url("tmdb")}

    ctx.use(PLUGIN_ROUTES).mount(ctx, router, zone="admin")
"""


def test_process_plugins_only_learn_the_proxy_of_their_own_service(tmp_path, monkeypatch) -> None:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal
    from movieclaw_net import EgressConfig, ProxyMode, apply_egress_config, get_egress_config

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'n.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "acme_relay.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.relay
              local: true
              module: acme_relay
              runtime: process
            """
        ),
        encoding="utf-8",
    )
    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    before = get_egress_config()
    try:
        with TestClient(app) as client:
            apply_egress_config(
                EgressConfig(
                    proxy_mode=ProxyMode.MANUAL,
                    proxy_url="http://user:secret@proxy.lan:7890",
                    proxy_services=frozenset({"relay", "tmdb"}),
                )
            )
            reply = client.get("/api/v1/plugins/acme.relay/proxy")
            assert reply.status_code == 200, reply.text
            assert reply.json() == {"own": "http://user:secret@proxy.lan:7890", "other": None}
    finally:
        apply_egress_config(before)
        for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
            del sys.modules[name]
        get_settings.cache_clear()


def _self_signed_cert(folder: Path) -> tuple[Path, Path]:
    """内网服务常见的自签证书：只认 127.0.0.1。"""
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "nas.local")])
    now = datetime.datetime.now(datetime.UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ip_address("127.0.0.1"))]), False
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()), False)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            True,
        )
        .sign(key, hashes.SHA256())
    )
    cert_path, key_path = folder / "nas.pem", folder / "nas.key"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return cert_path, key_path


@pytest.fixture
def https_url(tmp_path):
    """一台真实的自签 HTTPS 服务（内网的媒体服务器常见这样）。"""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args) -> None:
            pass

        def do_GET(self) -> None:  # noqa: N802
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

    cert, key = _self_signed_cert(tmp_path)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"https://127.0.0.1:{server.server_address[1]}/", cert
    server.shutdown()


@pytest.mark.parametrize("runtime", ["inline", "process"])
async def test_http_transport_verifies_certificates_unless_told_otherwise(
    https_url, runtime, monkeypatch
) -> None:
    url, cert = https_url
    if runtime == "process":
        # 进程外：代理地址向宿主问，建连接的是插件进程自己的 transport

        async def no_proxy(_service: str) -> None:
            return None

        monkeypatch.setattr(net, "_resolver", no_proxy)

    async def fetch(**kwargs) -> bytes:
        transport = net.http_transport("tls-check", **kwargs)
        async with httpx.AsyncClient(transport=transport, timeout=5.0) as client:
            return (await client.get(url)).content

    # 默认校验：自签证书连不上，凭据不会发给冒充的服务器
    with pytest.raises(httpx.ConnectError, match="(?i)certificate"):
        await fetch()
    # 指定 CA 文件：校验照做，只信这张证书
    assert await fetch(verify=str(cert)) == b"ok"
    # 用户显式关掉校验
    assert await fetch(verify=False) == b"ok"
    # 写错 CA 路径当场报错，不会悄悄退回不校验
    with pytest.raises(OSError):
        await fetch(verify=str(cert.with_name("missing.pem")))
