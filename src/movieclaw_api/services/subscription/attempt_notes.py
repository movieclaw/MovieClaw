"""下载尝试的清理/保留原因（``cleanup_note``）。

中文原文照旧写 ``cleanup_note``（旧版本回滚、诊断交接都读它），文案引用写
``cleanup_note_ref``，任务中心与活动流水按读者语言渲染。
"""

from __future__ import annotations

from movieclaw_api.i18n.stored import render_value, source_render, stored_message


def note_fields(ref: dict | None) -> dict:
    """两列一起写：``update().values(**note_fields(ref))`` 或列字典展开。"""
    return {"cleanup_note": source_render(ref) if ref else None, "cleanup_note_ref": ref}


def set_note(attempt, ref: dict | None) -> None:
    attempt.cleanup_note = source_render(ref) if ref else None
    attempt.cleanup_note_ref = ref


def render_note(text: str | None, ref: dict | None) -> str | None:
    """按读者语言渲染；旧记录只有中文原文时反查目录，查不到原样给。"""
    if ref:
        return render_value(ref)
    return stored_message(text) if text else None
