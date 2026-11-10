"""把推送文案收成飞书交互式卡片。

通道层拿得到的只有一段文本和可选的海报字节（见 services/push/im.py 的
``render``：标题、副标题、正文各一行）。评分、简介、按钮都从这段文本里取，
不补写推送里没有的字段。没有可展示的标题时返回 None，调用方改发纯文本。

卡片放不下的正文不丢：``layout_card`` 把卡片承载不了的部分作为 ``overflow`` 交回，
由适配器在卡片之后按纯文本分片补发。标题超长时完整标题行写进正文开头。
"""

from __future__ import annotations

import re
from urllib.parse import urlsplit

_MAX_BUTTONS = 3
_MAX_BUTTON_TEXT = 30
#: 飞书建议消息 JSON 控制在 30KB 左右。4000 字中文正文约 12KB，留足按钮和海报的余量。
#: 超出的正文不截断丢弃，交回调用方按文本补发。
_MAX_TITLE = 200
_MAX_SUMMARY = 4000
#: 正文里的 http(s) 链接；末尾标点在收集时剥掉，避免把句号算进地址
_URL_RE = re.compile(r"https?://[^\s<>\]\)\"']+")
_MD_LINK_RE = re.compile(r"\[([^\]\n]+)\]\((https?://[^)\s]+)\)")
_TRAILING = ".,;:!?)]}>\"'，。！？；、》」』"


def build_card(text: str, image_key: str | None = None) -> dict | None:
    """标题取第一个非空行，其余原文进正文。没有任何非空行时返回 None。

    只要卡片本身；放不下的正文见 ``layout_card``。
    """
    laid = layout_card(text, image_key)
    return None if laid is None else laid[0]


def layout_card(text: str, image_key: str | None = None) -> tuple[dict, str] | None:
    """返回 ``(卡片, overflow)``。``overflow`` 是卡片没装下、需要按文本补发的正文，可能为空。"""
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
    body_lines = [line for line in lines[rest_at:] if line]
    if len(title) > _MAX_TITLE:
        # 标题栏放不下:标题栏截断,完整标题放回正文开头,不丢字
        body_lines.insert(0, title)
        title = _clip_text(title, _MAX_TITLE)
    summary, overflow = _split_head("\n".join(body_lines).strip(), _MAX_SUMMARY)
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
    card = {
        "config": {"wide_screen_mode": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": "blue"},
        "elements": elements,
    }
    return card, overflow


def chunk_text(text: str, limit: int) -> list[str]:
    """按 ``limit`` 拆成多段纯文本。优先在换行处断开，单行超长时硬切。空文本返回空列表。"""
    chunks: list[str] = []
    rest = (text or "").strip()
    while rest:
        head, rest = _split_head(rest, limit)
        if head:
            chunks.append(head)
    return chunks


def _split_head(text: str, limit: int) -> tuple[str, str]:
    """切出不超过 ``limit`` 字的开头，返回 ``(开头, 剩余)``。不丢字符，只去掉断点处的换行。"""
    if len(text) <= limit:
        return text, ""
    cut = text.rfind("\n", 0, limit + 1)
    if cut <= limit // 2:
        # 找不到合适的换行(含单行超长):硬切
        return text[:limit], text[limit:].lstrip("\n")
    return text[:cut].rstrip(), text[cut + 1 :].lstrip("\n")


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
