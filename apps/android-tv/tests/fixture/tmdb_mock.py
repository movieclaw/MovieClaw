"""端到端夹具用的假 TMDB（docs/design/androidtv-app.md §7）。

数据来自 ``tmdb_catalog.json``：一批虚构的电影、剧集、季与影人（标题、简介、演职员、图片路径）。
图片不入库，请求时按路径现画：海报 / 剧照 / 片名 Logo / 头像，颜色由标题决定，画面上写着标题，
截图走查时一眼能对上是哪部片。

同时充当后端的 HTTP 代理（夹具给后端设 ``HTTP_PROXY`` 指到这里）：发往 image.tmdb.org 的取图请求
落到这里；其余外网请求一律 404，测试服务器因此碰不到真实网络。

  python tmdb_mock.py --port 8811
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import io
import json
import re
import sys
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from PIL import Image, ImageDraw, ImageFilter, ImageFont

CATALOG: dict[str, dict] = json.loads(
    (Path(__file__).with_name("tmdb_catalog.json")).read_text(encoding="utf-8")
)
FONT_PATHS = (
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
)

#: 图片路径 → (片名, 种类)。种类按命名约定：mc<id>p 海报、b 剧照、l Logo、mcpp<id> 头像、其余剧照
TITLES: dict[str, str] = {}


def _index_titles() -> None:
    for key, obj in CATALOG.items():
        title = obj.get("title") or obj.get("name")
        for field in ("poster_path", "backdrop_path", "profile_path", "still_path"):
            path = obj.get(field)
            if path and title:
                TITLES.setdefault(path, title)
        for image in (obj.get("images") or {}).get("logos", []):
            if title:
                TITLES.setdefault(image["file_path"], title)
        for ep in obj.get("episodes") or []:
            if ep.get("still_path"):
                TITLES.setdefault(ep["still_path"], f"{ep.get('name', '')}")
        for member in (obj.get("credits") or {}).get("cast", []) + (obj.get("credits") or {}).get(
            "crew", []
        ):
            if member.get("profile_path"):
                TITLES.setdefault(member["profile_path"], member["name"])
        if key.startswith("person/") and obj.get("profile_path"):
            TITLES[obj["profile_path"]] = obj["name"]


_index_titles()


@lru_cache(maxsize=8)
def _font(size: int) -> ImageFont.ImageFont:
    for path in FONT_PATHS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def _hue(text: str) -> float:
    return int(hashlib.md5(text.encode()).hexdigest()[:6], 16) / 0xFFFFFF


def _color(hue: float, light: float, sat: float = 0.55) -> tuple[int, int, int]:
    r, g, b = colorsys.hls_to_rgb(hue, light, sat)
    return int(r * 255), int(g * 255), int(b * 255)


def _canvas(size: tuple[int, int], seed: str) -> Image.Image:
    """渐变底 + 几块柔光，像一张失焦的剧照。"""
    hue = _hue(seed)
    w, h = size
    top, bottom = _color(hue, 0.18), _color((hue + 0.08) % 1, 0.42)
    img = Image.new("RGB", size)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        draw.line(
            [(0, y), (w, y)],
            fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom, strict=True)),
        )
    blobs = Image.new("RGBA", size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(blobs)
    digest = hashlib.sha1(seed.encode()).digest()
    for i in range(5):
        cx, cy = digest[i * 3] / 255 * w, digest[i * 3 + 1] / 255 * h
        r = (0.12 + digest[i * 3 + 2] / 255 * 0.2) * min(w, h)
        bd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*_color((hue + 0.5) % 1, 0.6), 90))
    blobs = blobs.filter(ImageFilter.GaussianBlur(min(w, h) / 12))
    img.paste(blobs, (0, 0), blobs)
    return img


def _render(path: str) -> tuple[bytes, str]:
    name = path.rsplit("/", 1)[-1]
    title = TITLES.get("/" + name, name.rsplit(".", 1)[0])
    if re.match(r"mc\d+l\.png$", name):  # 片名 Logo：透明底白字
        img = Image.new("RGBA", (680, 300), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        font = _font(150 if len(title) <= 4 else 110)
        box = draw.textbbox((0, 0), title, font=font)
        draw.text(((680 - box[2]) / 2, (300 - box[3]) / 2), title, font=font, fill="white")
        buf = io.BytesIO()
        img.save(buf, "PNG")
        return buf.getvalue(), "image/png"
    if name.startswith("mcpp"):  # 头像：竖图，大字写名字的第一个字
        img = _canvas((300, 450), title)
        draw = ImageDraw.Draw(img)
        font = _font(160)
        box = draw.textbbox((0, 0), title[:1], font=font)
        draw.text(((300 - box[2]) / 2, (450 - box[3]) / 2 - 20), title[:1], font=font, fill="white")
    elif re.match(r"mc\d+p\.jpg$", name) or "poster" in name:  # 海报
        img = _canvas((600, 900), title)
        draw = ImageDraw.Draw(img)
        draw.text((40, 700), title, font=_font(64), fill="white")
        draw.text((40, 790), "POSTER · TMDB MOCK", font=_font(26), fill=(255, 255, 255, 180))
    else:  # 背景图 / 分集剧照
        img = _canvas((1920, 1080), title)
        draw = ImageDraw.Draw(img)
        draw.text((1060, 1000), f"{title} · BACKDROP · TMDB MOCK", font=_font(40), fill="white")
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue(), "image/jpeg"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parts = urlsplit(self.path)
        host, path = parts.hostname, parts.path
        if host and host not in ("127.0.0.1", "localhost", "image.tmdb.org", "api.themoviedb.org"):
            return self._send(404, b"offline fixture", "text/plain")
        if path == "/health":
            return self._send(200, b'{"status":"ok"}', "application/json")
        if "/t/p/" in path:
            body, mime = _render(path)
            return self._send(200, body, mime, cache=True)
        key = path.split("/3/", 1)[-1].strip("/")
        if key in CATALOG:
            return self._send(
                200, json.dumps(CATALOG[key], ensure_ascii=False).encode(), "application/json"
            )
        if key.startswith(("discover/", "search/", "trending/")) or key.endswith(
            ("popular", "top_rated", "now_playing", "upcoming", "on_the_air", "airing_today")
        ):
            empty = {"page": 1, "results": [], "total_pages": 1, "total_results": 0}
            return self._send(200, json.dumps(empty).encode(), "application/json")
        self._send(404, b'{"status_code":34,"status_message":"not found"}', "application/json")

    def do_CONNECT(self) -> None:  # noqa: N802
        # https 外网：拒绝，夹具里的后端不该连外网
        self._send(403, b"offline fixture", "text/plain")

    def _send(self, status: int, body: bytes, mime: str, cache: bool = False) -> None:
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        if cache:
            self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"{self.command} {self.path} {args[1] if len(args) > 1 else ''}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8811)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
