"""网盘 strm 兼容矩阵（docs/design/strm-playback.md §8）。

按调研到的各家生成工具实际写进 strm 的内容逐一构造样本，起一个仿网盘生态的 HTTP 服务，
走真实的取流 / 探测接口验证「播放器拿到什么、服务端读到什么」：

- alist / OpenList ``/d/``（带 sign；115 存储 302 到网盘 CDN，本地存储 302 到自己的 ``/p/``）；
- CloudDrive2 ``/static/http/…/False/<整段编码的路径>``（CD2 自己出字节）；
- MoviePilot P115StrmHelper ``redirect_url?pickcode=&file_name=<原样中文>``、P123StrmHelper
  （``+`` 当空格）、p115nano302 ``http://host:8000?pickcode=``（没有路径）、qmediasync；
- SmartStrm 的 ``user:pass@host``；
- 网盘 CDN：直链与 User-Agent 绑定（115 的行为），换个 UA 就 403；过期的直链 403；
- 服务器本地路径（CD2 / rclone 挂载）：绝对路径、``file://``、相对路径、URL 编码过的路径、
  软链挂载点；以及必须拒绝的各种内容。

CDN 用一个公网样子的主机名：服务端替播放器跟跳转时不会去连它，测试再把地址换回本机验证
「播放器拿着这个地址、带自己的 UA 能取到字节」。真 ffprobe 的用例标 ``integration``。
"""

# ruff: noqa: F811 — 复用 test_playback_stream 的 client 夹具，用例参数与导入同名

from __future__ import annotations

import base64
import contextlib
import hashlib
import os
import re
import shutil
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, quote, unquote, urlencode

import httpx
import pytest
from tests.api.test_playback_stream import client, seed, start_session  # noqa: F401
from tests.playback.test_strm_playback import needs_ffmpeg, sample_mkv  # noqa: F401

from movieclaw_playback.streaming import StrmError, StrmLink, parse_strm

PLAYER_UA = "Infuse-Direct/8.1"
PUBLIC_CDN = "https://cdn.cloud-mock.com"
BODY = bytes(range(256)) * 64


class _Ecosystem:
    """仿网盘生态：各家工具的 302 服务 / 中转服务 + 与 UA 绑定的网盘 CDN。"""

    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}
        self.pickcodes: dict[str, str] = {}
        #: 302 服务把播放器跳到哪个 CDN；探测用例换成本机地址让 ffprobe 真能取到
        self.cdn_base = PUBLIC_CDN
        self.log: list[SimpleNamespace] = []
        eco = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                pass

            def do_HEAD(self) -> None:  # noqa: N802
                eco._handle(self, head=True)

            def do_GET(self) -> None:  # noqa: N802
                eco._handle(self, head=False)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def add(self, name: str, data: bytes, pickcode: str | None = None) -> None:
        self.files[name] = data
        if pickcode:
            self.pickcodes[pickcode] = name

    @staticmethod
    def sig(name: str, ua: str | None) -> str:
        return hashlib.sha1(f"{name}|{ua}".encode()).hexdigest()[:12]

    def cdn_url(self, name: str, ua: str | None) -> str:
        return f"{self.cdn_base}/cdn/{quote(name)}?sig={self.sig(name, ua)}"

    def local(self, url: str) -> str:
        """公网样子的 CDN 地址 → 本机上同一个地址（模拟播放器连上网盘 CDN）。"""
        return url.replace(PUBLIC_CDN, self.base, 1)

    def requests_to(self, prefix: str) -> list[SimpleNamespace]:
        return [r for r in self.log if r.path.startswith(prefix)]

    def _handle(self, h: BaseHTTPRequestHandler, *, head: bool) -> None:
        raw, _, query = h.path.partition("?")
        q = {k: v[0] for k, v in parse_qs(query).items()}
        ua = h.headers.get("User-Agent")
        self.log.append(
            SimpleNamespace(
                path=h.path,
                ua=ua,
                range=h.headers.get("Range"),
                auth=h.headers.get("Authorization"),
            )
        )
        path = unquote(raw)

        def redirect(location: str) -> None:
            h.send_response(302)
            h.send_header("Location", location)
            h.send_header("Content-Length", "0")
            h.end_headers()

        def by_pickcode() -> None:
            name = self.pickcodes.get(q.get("pickcode", ""))
            if name is None:
                h.send_error(404)
            else:
                redirect(self.cdn_url(name, ua))

        if path.startswith("/cdn/"):
            name = path.removeprefix("/cdn/")
            if q.get("expired") or q.get("sig") != self.sig(name, ua):
                h.send_error(403)  # 115：直链与取它的 User-Agent 绑定；过期一律 403
                return
            self._serve(h, name, head=head)
        elif path.startswith("/alist/d/"):
            if not q.get("sign"):
                h.send_error(401)
                return
            storage, _, name = path.removeprefix("/alist/d/").partition("/")
            if storage == "115":  # 115 存储不开代理：302 到网盘 CDN
                redirect(self.cdn_url(name, ua))
            else:  # 本地存储：302 到 alist 自己的 /p/（相对地址）
                redirect(f"/alist/p/{quote(name)}?sign={q['sign']}")
        elif path.startswith("/alist/p/"):
            self._serve(h, path.removeprefix("/alist/p/"), head=head)
        elif (
            path.startswith("/mp/api/v1/plugin/P115StrmHelper/redirect_url")
            or (raw == "/" and "pickcode" in q)  # p115nano302：http://host:8000?pickcode=…
            or path == "/115/url/video.mkv"  # qmediasync
        ):
            by_pickcode()
        elif path.startswith("/mp/api/v1/plugin/P123StrmHelper/redirect_url"):
            name = q.get("name", "")
            if name in self.files:
                redirect(self.cdn_url(name, ua))
            else:
                h.send_error(404)
        elif path.startswith("/static/http/"):  # CD2：路径整段编码在最后，自己出字节
            assert "%2F" in raw, raw  # 编码过的斜杠必须原样到达
            self._serve(h, path.rpartition("/")[2], head=head)
        elif path.startswith("/smartstrm/"):
            expected = "Basic " + base64.b64encode(b"user:p@ss").decode()
            if h.headers.get("Authorization") != expected:
                h.send_response(401)  # 真 WebDAV 都带质询头：ffmpeg 见到它才发凭据
                h.send_header("WWW-Authenticate", 'Basic realm="smartstrm"')
                h.send_header("Content-Length", "0")
                h.end_headers()
                return
            self._serve(h, path.rpartition("/")[2], head=head)
        else:
            h.send_error(404)

    def _serve(self, h: BaseHTTPRequestHandler, name: str, *, head: bool) -> None:
        data = self.files.get(name)
        if data is None:
            h.send_error(404)
            return
        size = len(data)
        match = re.match(r"bytes=(\d+)-(\d*)", h.headers.get("Range") or "")
        if match:
            start = int(match.group(1))
            end = min(int(match.group(2)) if match.group(2) else size - 1, size - 1)
            body = data[start : end + 1]
            h.send_response(206)
            h.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            body = data
            h.send_response(200)
        h.send_header("Content-Type", "video/x-matroska")
        h.send_header("Content-Length", str(len(body)))
        h.send_header("Accept-Ranges", "bytes")
        h.end_headers()
        if not head:
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                h.wfile.write(body)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def eco():
    server = _Ecosystem()
    yield server
    server.close()


def _play(
    client, tmp_path, content: str, *, container: str = "mp4", ua: str = PLAYER_UA, rng="bytes=0-99"
):
    """把 ``content`` 写成一个 strm 入库，按播放器的样子取一次流（不跟随跳转）。"""
    file_id = seed(client, tmp_path, container=container, strm=True, strm_url=content)
    url = start_session(client, file_id)["stream_url"]
    return client.get(url, headers={"Range": rng, "User-Agent": ua}, follow_redirects=False)


# ---------------------------------------------------------------------------
# 内网 302 服务：服务端带播放器的 UA 替它跟跳转，把播放器 302 到网盘 CDN
# ---------------------------------------------------------------------------

_NAME = "星际 穿越 (2014).mkv"
_PC = "ecmrzjm7k2lqlv0aa"


@pytest.mark.parametrize(
    ("tool", "template", "seen_prefix"),
    [
        (
            "alist 115 存储（/d/ 带 sign）",
            "{base}/alist/d/115/{qname}?sign=Xyz=:0",
            "/alist/d/115/",
        ),
        (
            "P115StrmHelper（file_name 原样中文与空格）",
            "{base}/mp/api/v1/plugin/P115StrmHelper/redirect_url?pickcode={pc}&file_name={name}",
            "/mp/api/v1/plugin/P115StrmHelper/",
        ),
        ("p115nano302（? 前没有路径）", "{base}?pickcode={pc}", "/?pickcode="),
        ("qmediasync", "{base}/115/url/video.mkv?pickcode={pc}&userid=1&path={qname}", "/115/url/"),
        (
            "P123StrmHelper（urlencode，+ 当空格）",
            "{base}/mp/api/v1/plugin/P123StrmHelper/redirect_url?{p123}",
            "/mp/api/v1/plugin/P123StrmHelper/",
        ),
    ],
)
def test_lan_302_service_sends_player_to_cloud_cdn(
    client, tmp_path, eco, tool, template, seen_prefix
):
    eco.add(_NAME, BODY, pickcode=_PC)
    content = template.format(
        base=eco.base,
        qname=quote(_NAME),
        name=_NAME,
        pc=_PC,
        p123=urlencode({"name": _NAME, "size": len(BODY), "md5": "x" * 32}),
    )
    resp = _play(client, tmp_path, content)
    assert resp.status_code == 302, (tool, resp.text)
    location = resp.headers["location"]
    assert location.startswith(f"{PUBLIC_CDN}/cdn/"), (tool, location)
    # 服务端替播放器问 302 服务时带的是播放器自己的 UA，没有拉片子本体
    asked = eco.requests_to(seen_prefix)
    assert asked and {r.ua for r in asked} == {PLAYER_UA}, tool
    assert not eco.requests_to("/cdn/")
    # 播放器拿着这个地址、带自己的 UA 去网盘 CDN 能取到字节；换个 UA 就是 403（直链与 UA 绑定）
    ok = httpx.get(eco.local(location), headers={"User-Agent": PLAYER_UA, "Range": "bytes=0-99"})
    assert ok.status_code == 206 and ok.content == BODY[:100], tool
    other = httpx.get(eco.local(location), headers={"User-Agent": "curl/8", "Range": "bytes=0-99"})
    assert other.status_code == 403


def test_lan_alist_serving_bytes_itself_is_relayed(client, tmp_path, eco):
    """alist 本地存储：/d/ 302 到自己的 /p/（相对地址、仍在内网）→ 跟到底也出不去，服务端转发。"""
    eco.add(_NAME, BODY)
    resp = _play(
        client, tmp_path, f"{eco.base}/alist/d/local/{quote(_NAME)}?sign=abc", rng="bytes=100-199"
    )
    assert resp.status_code == 206 and resp.content == BODY[100:200]
    assert resp.headers["content-range"] == f"bytes 100-199/{len(BODY)}"
    assert eco.requests_to("/alist/p/")


@pytest.mark.parametrize(
    ("tool", "make"),
    [
        (
            "CloudDrive2 /static（整段路径编码，%2F 不能被解开）",
            lambda base: (
                f"{base}/static/http/127.0.0.1:19798/False/" + quote(f"/115/电影/{_NAME}", safe="")
            ),
        ),
        (
            "SmartStrm（地址里带账号密码）",
            lambda base: (
                base.replace("http://", "http://user:p%40ss@") + f"/smartstrm/115/{quote(_NAME)}"
            ),
        ),
        (
            "Kodi 请求头后缀",
            lambda base: f"{base}/alist/d/local/{quote(_NAME)}?sign=1|User-Agent=115Browser%2F27",
        ),
    ],
)
def test_lan_services_that_serve_bytes_are_relayed(client, tmp_path, eco, tool, make):
    eco.add(_NAME, BODY)
    resp = _play(client, tmp_path, make(eco.base), rng="bytes=16-31")
    assert resp.status_code == 206 and resp.content == BODY[16:32], (tool, resp.text)


def test_strm_headers_win_over_the_player_ua(client, tmp_path, eco):
    eco.add(_NAME, BODY)
    _play(
        client,
        tmp_path,
        f"{eco.base}/alist/d/local/{quote(_NAME)}?sign=1|User-Agent=115Browser%2F27",
    )
    assert {r.ua for r in eco.requests_to("/alist/")} == {"115Browser/27"}


def test_credentials_in_a_public_url_are_never_handed_to_the_player(client, tmp_path):
    """带账号密码的公网地址也不 302：浏览器拒绝带凭据的媒体地址，凭据也不该给播放器。"""
    resp = _play(client, tmp_path, "https://user:secret@dav.example.com/smartstrm/a.mkv")
    assert resp.status_code != 302


def test_lan_302_service_down_falls_back_to_relay_and_reports_bad_gateway(client, tmp_path):
    resp = _play(
        client,
        tmp_path,
        "http://127.0.0.1:9/mp/api/v1/plugin/P115StrmHelper/redirect_url?pickcode=x",
    )
    assert resp.status_code == 502


# ---------------------------------------------------------------------------
# 公网直链：原样 302，不重新编码
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "https://alist.example.com/d/电影/星际 穿越.mkv?sign=Xyz=:0",  # AutoFilm：sign 原样带 =:
        "https://alist.example.com/d/%E7%94%B5%E5%BD%B1/a%20b.mkv?sign=abc",  # 逐段编码
        "https://cd2.example.com/static/https/cd2.example.com/False/%2F115%2Fa.mkv",  # %2F 不解开
        "http://p115.example.com:8000?pickcode=abc&c=0&f=",  # ? 前没有路径
        "https://p123.example.com/redirect_url?name=a+b.mkv&size=1",  # + 当空格
    ],
)
def test_public_urls_are_redirected_without_reencoding(client, tmp_path, url):
    resp = _play(client, tmp_path, url)
    assert resp.status_code == 302
    location = resp.headers["location"]
    # 已有的编码（%2F、%20）原样保留；原样中文与空格只做必要的百分号编码
    assert unquote(location) == unquote(url)
    for kept in ("%2F", "%20", "=:", "+"):
        if kept in url:
            assert kept in location


# ---------------------------------------------------------------------------
# 文件编码与格式（Kodi / Jellyfin 的写法）
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "url"),
    [
        (b"\xef\xbb\xbfhttps://a.example.com/x.mkv\n", "https://a.example.com/x.mkv"),  # BOM
        (b"https://a.example.com/x.mkv\r\n", "https://a.example.com/x.mkv"),  # CRLF
        (b"\t https://a.example.com/x.mkv \t\n", "https://a.example.com/x.mkv"),
        ("https://a.example.com/电影.mkv\n".encode("gb18030"), "https://a.example.com/电影.mkv"),
        (
            b"#EXTM3U\n#EXTINF:-1,x\n#KODIPROP:inputstream=x\n\nhttps://a.example.com/1.mkv\n"
            b"https://a.example.com/2.mkv\n",
            "https://a.example.com/1.mkv",
        ),
    ],
)
def test_strm_text_variants(tmp_path, raw, url):
    strm = tmp_path / "a.strm"
    strm.write_bytes(raw)
    source = parse_strm(strm)
    assert isinstance(source, StrmLink) and source.url == url


def test_bom_strm_plays_end_to_end(client, tmp_path):
    resp = _play(client, tmp_path, "\ufeffhttps://pan.example.com/a.mkv\r")
    assert resp.status_code == 302 and resp.headers["location"] == "https://pan.example.com/a.mkv"


# ---------------------------------------------------------------------------
# 服务器本地路径（CloudDrive2 / rclone 挂载）
# ---------------------------------------------------------------------------


@pytest.fixture
def mount(tmp_path) -> Path:
    """仿 CD2 挂载：反馈者的路径形态（中文目录、S01E82）。"""
    target = tmp_path / "CloudNAS" / "115" / "国产剧" / "帐中香" / "帐中香.S01E82.mkv"
    target.parent.mkdir(parents=True)
    target.write_bytes(BODY)
    return target


@pytest.mark.parametrize(
    "form",
    ["absolute", "file-uri", "file-localhost", "relative", "percent-encoded", "symlinked-mount"],
)
def test_local_path_strm_is_served_like_a_local_file(client, tmp_path, mount, form):
    link = tmp_path / "mnt"
    link.symlink_to(tmp_path / "CloudNAS")
    content = {
        "absolute": str(mount),
        "file-uri": "file://" + quote(str(mount)),
        "file-localhost": "file://localhost" + str(mount),
        "percent-encoded": quote(str(mount)),
        "symlinked-mount": str(link / mount.relative_to(tmp_path / "CloudNAS")),
        # 相对 strm 所在目录（seed 把 strm 放在 tmp_path/movies<n>/ 下）
        "relative": os.path.relpath(mount, tmp_path / "movies0"),
    }[form]
    resp = _play(client, tmp_path, content)
    assert resp.status_code == 206, (form, resp.text)
    assert resp.content == BODY[:100]
    assert resp.headers["content-range"] == f"bytes 0-99/{len(BODY)}"


def test_local_path_strm_full_read(client, tmp_path, mount):
    file_id = seed(client, tmp_path, container="mp4", strm=True, strm_url=str(mount))
    resp = client.get(start_session(client, file_id)["stream_url"])
    assert resp.status_code == 200 and resp.content == BODY
    assert resp.headers["content-length"] == str(len(BODY))  # 真实文件的大小，不是 strm 文本的


def test_local_path_strm_remux_reads_the_mount_file_directly(client, tmp_path, mount, monkeypatch):
    """服务端换封装时 ffmpeg 直接读挂载文件：不加只放行网络协议的白名单。"""
    from tests.api.test_playback_stream import FAKE_FFMPEG

    from movieclaw_api.api.routes import playback as routes_playback
    from movieclaw_api.services.playback import session as session_mod
    from movieclaw_api.services.playback.ffmpeg_args import TranscodeCommand

    builds = []

    def capture_build(plan, *, source_path, session_dir, input_options=(), **_kwargs):
        builds.append((source_path, list(input_options)))
        playlist = Path(session_dir) / "index.m3u8"
        return TranscodeCommand(
            argv=["python3", "-c", FAKE_FFMPEG, str(playlist)],
            playlist_path=playlist,
            init_path=Path(session_dir) / "init.mp4",
        )

    monkeypatch.setattr(session_mod, "build_hls_command", capture_build)
    monkeypatch.setattr(routes_playback, "read_keyframe_index", lambda *_a, **_k: None)
    file_id = seed(client, tmp_path, container="mkv", strm=True, strm_url=str(mount))
    data = start_session(client, file_id)
    assert data["decision"]["tier"] == 1 and data["session_id"]
    assert builds[0] == (str(mount.resolve()), [])


@pytest.mark.parametrize(
    ("content", "reason"),
    [
        ("/etc/passwd", "不是视频文件"),
        ("{db}", "不是视频文件"),  # 数据库：Jellyfin 那次漏洞读的就是它
        ("{evil}", "不是视频文件"),  # 起名 .mkv 的软链指向密钥
        ("{other_strm}", "不是视频文件"),  # 指向另一个 strm
        ("{dir}", "不是视频文件"),  # 目录
        (r"D:\Movies\a.mkv", "Windows 路径"),
        (r"\\NAS\share\a.mkv", "Windows 路径"),
        ("smb://nas/share/a.mkv", "不支持 smb://"),
        ("nfs://nas/share/a.mkv", "不支持 nfs://"),
        ("rtmp://live.example.com/a", "不支持 rtmp://"),
        ("redirect115&ecmrzjm7k2lqlv0aa", "既不是"),
        ("/CloudNAS/115/不存在.mkv", "找不到"),
        ("file://otherhost/a.mkv", "别的主机"),
        ("#EXTM3U\n# 只有注释", "没有播放地址"),
    ],
)
def test_unusable_strm_is_rejected_with_a_reason(client, tmp_path, content, reason):
    secret = tmp_path / ".secret_key"
    secret.write_text("TOP-SECRET")
    evil = tmp_path / "evil.mkv"
    evil.symlink_to(secret)
    other = tmp_path / "other.strm"
    other.write_text("https://pan.example.com/a.mkv\n")
    (tmp_path / "dir.mkv").mkdir()
    content = content.format(
        db=tmp_path / "test.db", evil=evil, other_strm=other, dir=tmp_path / "dir.mkv"
    )
    resp = _play(client, tmp_path, content)
    assert resp.status_code == 404, resp.text
    assert reason in resp.text
    assert b"TOP-SECRET" not in resp.content and b"SQLite" not in resp.content


# ---------------------------------------------------------------------------
# 服务端读源：规格探测（真 ffprobe）
# ---------------------------------------------------------------------------


def _probe(client, tmp_path, content: str) -> dict:
    file_id = seed(client, tmp_path, container="strm", codec=None, strm=True, strm_url=content)
    resp = client.post(f"/api/v1/library-strm/files/{file_id}/probe")
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def test_expired_link_is_reported_as_expired(client, tmp_path, eco):
    eco.add(_NAME, BODY)
    data = _probe(client, tmp_path, f"{eco.base}/cdn/{quote(_NAME)}?sig=old&expired=1")
    assert data["status"] == "failed"
    assert "直链已失效或无权访问（HTTP 403）" in data["error"]


def test_bad_strm_probe_reports_the_parse_reason(client, tmp_path):
    data = _probe(client, tmp_path, "smb://nas/share/a.mkv")
    assert data["status"] == "failed" and "不支持 smb://" in data["error"]


@pytest.mark.integration
@needs_ffmpeg
@pytest.mark.parametrize(
    "template",
    [
        "{base}/alist/d/115/{qname}?sign=Xyz=:0",
        "{base}/alist/d/local/{qname}?sign=abc",
        "{base}/mp/api/v1/plugin/P115StrmHelper/redirect_url?pickcode={pc}&file_name={name}",
        "{base}?pickcode={pc}",
        "{base}/115/url/video.mkv?pickcode={pc}&userid=1",
        "{base}/mp/api/v1/plugin/P123StrmHelper/redirect_url?{p123}",
        "{base}/static/http/127.0.0.1:19798/False/{cd2}",
        "{auth_base}/smartstrm/115/{qname}",
        "{base}/alist/d/local/{qname}?sign=1|User-Agent=115Browser%2F27",
        "{local}",
    ],
)
def test_server_side_probe_reads_every_form(client, tmp_path, eco, sample_mkv, mount, template):
    """服务端（ffprobe）按每种写法读源：302 服务、中转、带凭据、带请求头、本地挂载都读得出规格。"""
    eco.add(_NAME, sample_mkv.read_bytes(), pickcode=_PC)
    eco.cdn_base = eco.base  # 让 ffprobe 跟着 302 真能连上「网盘 CDN」
    shutil.copy(sample_mkv, mount)
    content = template.format(
        base=eco.base,
        auth_base=eco.base.replace("http://", "http://user:p%40ss@"),
        qname=quote(_NAME),
        name=_NAME,
        pc=_PC,
        p123=urlencode({"name": _NAME, "size": 1}),
        cd2=quote(f"/115/电影/{_NAME}", safe=""),
        local=mount,
    )
    data = _probe(client, tmp_path, content)
    assert data["status"] == "probed", (content, data)
    assert data["container"] == "mkv" and data["video_codec"] == "h264"


# ---------------------------------------------------------------------------
# 本地路径 strm 的按索引读：关键帧、字幕块（与本地文件同一套读取器，不通读）
# ---------------------------------------------------------------------------


@pytest.mark.integration
@needs_ffmpeg
def test_local_path_strm_index_reads_match_the_local_file(tmp_path, sample_mkv, mount):
    from movieclaw_api.services import media_extract
    from movieclaw_playback.keyframes import read_keyframe_index

    shutil.copy(sample_mkv, mount)
    strm = tmp_path / "local.strm"
    strm.write_text(f"{mount}\n", encoding="utf-8")
    via_strm = read_keyframe_index(strm, allow_ffprobe=False)
    direct = read_keyframe_index(sample_mkv, allow_ffprobe=False)
    assert via_strm is not None and via_strm.times_s == direct.times_s
    assert media_extract._sparse_tracks(strm) is not None


def test_parse_strm_local_target_is_the_resolved_file(tmp_path, mount):
    strm = tmp_path / "a.strm"
    strm.write_text(f"{mount}\n")
    assert parse_strm(strm) == mount.resolve()
    strm.write_text("/etc/passwd\n")
    with pytest.raises(StrmError, match="不是视频文件"):
        parse_strm(strm)


def test_relative_path_is_resolved_against_the_strm_folder(tmp_path, mount):
    strm_dir = tmp_path / "library" / "帐中香"
    strm_dir.mkdir(parents=True)
    strm = strm_dir / "帐中香.S01E82.strm"
    strm.write_text(os.path.relpath(mount, strm_dir) + "\n")
    assert parse_strm(strm) == mount.resolve()
