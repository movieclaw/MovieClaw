"""插件声明的通知规则（docs/design/domain-events.md §7）：模板只做字段替换，标明来自哪个插件。"""

from __future__ import annotations

import re
from typing import Any


def template_rule(item: Any, spec: Any) -> Any:
    from movieclaw_api.services.push.rules import Audience, Rule

    kind, _, path = spec.audience.partition(":")
    audience = (
        Audience.admins()
        if kind == "admins"
        else Audience.member(path)
        if kind == "member"
        else Audience.media(path)
    )
    return Rule(
        event=spec.event,
        title=item.events.get(spec.event, spec.event),
        description=spec.description or f"来自插件「{item.title}」",
        group=f"插件 · {item.title}",
        default=spec.default,
        audience=audience,
        render=_renderer(item, spec, audience),
        admin_only=kind == "admins",
        owner=item.entry_id,
    )


_FIELD = re.compile(r"\{([\w.]+)\}")


def fill(template: str, payload: Any) -> str:
    """模板只做字段替换：``{site}``、``{media.title}``；取不到的换成空串。"""
    from movieclaw_api.services.push.rules import field_value

    def one(match: re.Match[str]) -> str:
        value = field_value(payload, match.group(1))
        if value is None:
            return ""
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        return str(value)

    return _FIELD.sub(one, template).strip()


def _renderer(item: Any, spec: Any, audience: Any):  # type: ignore[no-untyped-def]
    async def render(session: Any, member_id: int, payload: Any) -> Any:
        from movieclaw_api.services.push.audience import library_path
        from movieclaw_api.services.push.engine import media_of
        from movieclaw_api.services.push.notify import AlertContent

        open_path = f"/settings/plugins?module={item.entry_id}"
        if spec.open == "media":
            media = media_of(payload, audience)
            if media is not None:
                open_path = await library_path(session, member_id, media.id, None) or open_path
        return AlertContent(
            title=fill(spec.title, payload) or item.events.get(spec.event, spec.event),
            # 通知上标来源：插件不能冒充系统通知
            subtitle=f"来自 {item.title}",
            body=fill(spec.body, payload),
            open=open_path,
            thread=f"plugin:{item.entry_id}",
            level=spec.level,
        )

    return render
