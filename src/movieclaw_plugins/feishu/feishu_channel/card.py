"""把推送文案收成飞书交互式卡片。

通道层拿得到的只有一段文本和可选的海报字节（见 services/push/im.py 的
``render``：标题、副标题、正文各一行）。评分、简介、按钮都从这段文本里取，
不补写推送里没有的字段。没有可展示的标题时返回 None，调用方改发纯文本。
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit

_MAX_BUTTONS = 3
_MAX_BUTTON_TEXT = 30
#: 卡片 JSON 大约 30KB。标题和简介截断后仍带海报与按钮；更长的正文不另发一条。
_MAX_TITLE = 200
_MAX_SUMMARY = 4000
#: 正文里的 http(s) 链接；末尾标点在收集时剥掉，避免把句号算进地址
_URL_RE = re.compile(r"https?://[^\s<>\]\)\"']+")
_MD_LINK_RE = re.compile(r"\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
_TRAILING = ".,;:!?)]}>\"'，。！？；、》」』"


def build_card(text: str, image_key: str | None = None) -> dict | None:
    """标题取第一个非空行，其余原文进正文。没有任何非空行时返回 None。"""
    raw = text or ""
    lines = [line.strip() for line in raw.splitlines()]
    title = ""
    rest_at = 0
    for index, line in enumerate(lines):
        if line:
            title = line
            rest_at = index + 1
            break
    if not title:
        return None
    title = _clip_text(title, _MAX_TITLE)
    summary = _clip_text("\n".join(line for line in lines[rest_at:] if line).strip(), _MAX_SUMMARY)
    elements: list[dict] = []
    if image_key:
        elements.append(
            {
                "tag": "img",
                "img_key": image_key,
                "alt": {"tag": "plain_text", "content": title},
            }
        )
    # 没有图也没有正文时仍留一块正文，避免 elements 为空被飞书拒收
    body = summary or ("" if image_key else title)
    if body:
        elements.append({"tag": "div", "text": {"tag": "lark_md", "content": body}})
    buttons = _buttons(raw)
    if buttons:
        elements.append(
            {
                "tag": "action",
                "actions": [
                    {
                        "tag": "button",
                        "text": {"tag": "plain_text", "content": label},
                        "type": "primary" if index == 0 else "default",
                        "url": url,
                    }
                    for index, (label, url) in enumerate(buttons)
                ],
            }
        )
    return {
        "config": {"wide_screen_mode": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": "blue"},
        "elements": elements,
    }


def _buttons(text: str) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    seen: set[str] = set()
    for match in _MD_LINK_RE.finditer(text):
        url = _trim_url(match.group(2))
        label = match.group(1).strip() or _host(url)
        _add_button(found, seen, label, url)
        if len(found) >= _MAX_BUTTONS:
            return found
    for match in _URL_RE.finditer(text):
        url = _trim_url(match.group(0))
        _add_button(found, seen, _host(url), url)
        if len(found) >= _MAX_BUTTONS:
            break
    return found


def _add_button(found: list[tuple[str, str]], seen: set[str], label: str, url: str) -> None:
    if not url.startswith(("http://", "https://")) or url in seen or not label:
        return
    seen.add(url)
    found.append((_clip(label), url))


def _trim_url(url: str) -> str:
    return url.rstrip(_TRAILING)


def _host(url: str) -> str:
    return urlsplit(url).hostname or ""


def _clip(text: str) -> str:
    return text[:_MAX_BUTTON_TEXT]


def _clip_text(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"
