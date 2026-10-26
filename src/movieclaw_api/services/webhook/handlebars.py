"""最小 Handlebars 渲染器（docs/design/webhook.md §3.4）。

只为一件事服务：让用户把下游文档里「贴进 Jellyfin Webhook 插件」的同一段
模板原样贴进 MovieClaw。因此语法面向官方插件的实际能力收敛，实现其模板
变量替换 + 全部 5 个官方助手，不追求完整 Handlebars：

- ``{{Var}}``（HTML 转义，与 Handlebars 默认一致）与 ``{{{Var}}}``（原样）；
- 块助手 ``{{#if_equals A B}}…{{else}}…{{/if_equals}}``（大小写不敏感比较）、
  ``{{#if_exist A}}…{{else}}…{{/if_exist}}``（非空判断）；
- 行内助手 ``{{link_to url text}}`` / ``{{url_encode Var}}`` / ``{{json_encode Var}}``；
- 空白控制 ``{{~ … ~}}``；参数支持变量名与 ``'…'`` / ``"…"`` 字符串字面量。

未知变量渲染为空串（插件行为）；未知助手/未闭合块直接抛
``TemplateError``——渲染失败会进投递记录并以中文报错，绝不静默吞掉。
布尔值按 .NET 习惯渲染为 ``True`` / ``False``（比较端大小写不敏感，无碍）。
"""

from __future__ import annotations

import html
import json
import re
import urllib.parse

_TAG_RE = re.compile(r"\{\{\{(.*?)\}\}\}|\{\{(.*?)\}\}", re.DOTALL)
# 参数切分：带引号的字符串字面量或裸 token
_ARG_RE = re.compile(r"'[^']*'|\"[^\"]*\"|\S+")

_BLOCK_HELPERS = ("if_equals", "if_exist")


class TemplateError(ValueError):
    """Keep the original diagnostic beside an optional display reference."""

    def __init__(self, message: str, *, message_key: str | None = None, params: dict | None = None):
        super().__init__(message)
        self.message_key = message_key
        self.params = params or {}


def _stringify(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "True" if value else "False"
    return str(value)


def _resolve(token: str, values: dict) -> str:
    """参数求值：引号字面量原样，其余按变量名查表（缺失 = 空串）。"""
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "'\"":
        return token[1:-1]
    return _stringify(values.get(token))


def _apply_inline(name: str, args: list[str], values: dict) -> str:
    resolved = [_resolve(a, values) for a in args]
    if name == "url_encode":
        return urllib.parse.quote(resolved[0] if resolved else "", safe="")
    if name == "json_encode":
        return json.dumps(resolved[0] if resolved else "", ensure_ascii=False)
    if name == "link_to":
        url = resolved[0] if resolved else ""
        text = resolved[1] if len(resolved) > 1 else url
        return f'<a href="{url}">{text}</a>'
    raise TemplateError(
        f"模板使用了不支持的助手：{name}"
        "（支持 if_equals / if_exist / link_to / url_encode / json_encode）",
        message_key="settings.webhook.template.unsupportedHelper",
        params={"name": name},
    )


def _block_truth(name: str, args: list[str], values: dict) -> bool:
    if name == "if_equals":
        left = _resolve(args[0], values) if args else ""
        right = _resolve(args[1], values) if len(args) > 1 else ""
        return left.casefold() == right.casefold()
    # if_exist：值非 null 且非空串
    return bool(_resolve(args[0], values)) if args else False


def render(template: str, values: dict) -> str:
    """用变量字典渲染模板；语法错误抛 ``TemplateError``。"""
    out: list[str] = []
    # 块栈：每层 = [助手名, 判断结果, 是否已进入 else 分支]；助手名用于校验
    # 闭合标签配对，输出仅在所有层都"当前分支成立"时写入
    stack: list[list] = []
    pos = 0
    pending_trim = False  # 上一个标签带 ~}}：吞掉后续空白

    def emit(text: str) -> None:
        nonlocal pending_trim
        if pending_trim:
            text = text.lstrip()
            pending_trim = False
        if text and all(layer[1] != layer[2] for layer in stack):
            # layer = [助手名, 判断结果, 在else分支]：
            # 真分支且未进 else，或假分支且已进 else，才可见
            out.append(text)

    for match in _TAG_RE.finditer(template):
        literal = template[pos : match.start()]
        raw_inner = match.group(1) if match.group(1) is not None else match.group(2)
        escape = match.group(1) is None  # {{ }} 转义，{{{ }}} 原样
        inner = raw_inner.strip()
        # {{~ ：只修剪**紧邻本标签之前的源文本段**的尾部空白——不回头改动
        # 已产出的输出（隐藏分支里的标签不该影响可见文本，也不该越过前一个标签）
        if inner.startswith("~"):
            literal = literal.rstrip()
            inner = inner[1:].strip()
        # ~}}：吞掉标签**之后**文本的前导空白——标签自身的输出不受影响，
        # 所以先记在本地，待本标签输出完毕再置位 pending_trim
        trim_after = inner.endswith("~")
        if trim_after:
            inner = inner[:-1].strip()
        emit(literal)

        if inner.startswith("!"):  # 注释
            pending_trim = pending_trim or trim_after
            pos = match.end()
            continue
        if inner.startswith("#"):
            parts = _ARG_RE.findall(inner[1:])
            name, args = parts[0], parts[1:]
            if name not in _BLOCK_HELPERS:
                raise TemplateError(
                    f"模板使用了不支持的块助手：{name}",
                    message_key="settings.webhook.template.unsupportedBlock",
                    params={"name": name},
                )
            stack.append([name, _block_truth(name, args, values), False])
        elif inner.startswith("/"):
            name = inner[1:].strip()
            if not stack or stack[-1][0] != name:
                raise TemplateError(
                    f"模板的闭合标签 {{{{/{name}}}}} 与当前打开的块不匹配",
                    message_key="settings.webhook.template.closingMismatch",
                    params={"tag": "{{/" + name + "}}"},
                )
            stack.pop()
        elif inner == "else":
            if not stack:
                raise TemplateError(
                    "模板的 {{else}} 不在任何块助手内",
                    message_key="settings.webhook.template.elseOutside",
                    params={"tag": "{{else}}"},
                )
            if stack[-1][2]:
                raise TemplateError(
                    "同一个块助手里出现了重复的 {{else}}",
                    message_key="settings.webhook.template.duplicateElse",
                    params={"tag": "{{else}}"},
                )
            stack[-1][2] = True
        else:
            parts = _ARG_RE.findall(inner)
            if len(parts) > 1:
                # 助手输出视为 SafeString（不再转义）：json_encode/url_encode
                # 的产物再转义会破坏 JSON/URL 语义
                emit(_apply_inline(parts[0], parts[1:], values))
            else:
                text = _stringify(values.get(parts[0])) if parts else ""
                emit(html.escape(text, quote=False) if escape else text)
        pending_trim = pending_trim or trim_after
        pos = match.end()

    emit(template[pos:])
    if stack:
        raise TemplateError(
            "模板存在未闭合的块助手（缺少 {{/if_…}}）",
            message_key="settings.webhook.template.unclosed",
            params={"tag": "{{/if_…}}"},
        )
    return "".join(out)
