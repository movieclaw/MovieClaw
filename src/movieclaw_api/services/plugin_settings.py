"""插件通用设置：读 Schema 与当前值、保存并重启插件（docs/design/plugin-phase4.md §3）。

值的来源两层：清单配置（本地插件的 ``plugins.yaml``）打底，
界面保存的（``plugins/settings_store.py``）优先。
敏感字段（Schema 里 ``writeOnly``）只回「已设置」，保存时留空表示不改。

保存后重启插件让新值生效；重启失败就恢复旧设置、再重启一次，把失败原因交给调用方——
不能让一次填错把插件留在起不来的状态。
"""

from __future__ import annotations

import logging
from typing import Any

from movieclaw_api.exceptions import BadRequestException, NotFoundException
from movieclaw_api.i18n import t
from movieclaw_api.i18n.metadata import localized_schema
from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.plugins import settings_store
from movieclaw_kernel import Kernel
from movieclaw_kernel.kernel import State
from movieclaw_sdk.config_schema import describe_config, secret_fields

logger = logging.getLogger("movieclaw_api.plugins")

#: 内核禁用来源：保存设置时的短暂重启（与用户手动停用区分）
RESTART_SOURCE = "settings"


def description(kernel: Kernel, entry_id: str) -> dict[str, Any] | None:
    """插件配置的描述：``{"schema": …}`` / ``{"unsupported": 原因}``；没有配置模型为 None。"""
    from movieclaw_api.services import plugin_runtime

    fiber = kernel.fiber(entry_id)
    if fiber is None:
        raise NotFoundException(message_key="errors.plugins.missing", params={"id": entry_id})
    # 进程外插件的模型在子进程里，主进程只有它报上来的描述
    if entry_id in plugin_runtime.config_descriptions:
        return plugin_runtime.config_descriptions[entry_id]
    return describe_config(fiber.plugin.config)


def view(kernel: Kernel, settings: Any, entry_id: str) -> dict[str, Any]:
    """接口返回：Schema、当前值（敏感字段不回显）、哪些敏感字段已设置。"""
    desc = description(kernel, entry_id)
    if desc is None:
        return {"editable": False, "reason": None, "schema": None, "values": {}, "secrets_set": []}
    if "schema" not in desc:
        return {
            "editable": False,
            "reason": desc.get("unsupported"),
            "schema": None,
            "values": {},
            "secrets_set": [],
        }
    schema = desc["schema"]
    secrets = secret_fields(schema)
    merged = _merged(kernel, settings, entry_id)
    values = {
        name: merged.get(name, prop.get("default"))
        for name, prop in schema["properties"].items()
        if name not in secrets
    }
    return {
        "editable": True,
        "reason": None,
        "schema": localized_schema(schema),
        "values": values,
        "secrets_set": sorted(name for name in secrets if merged.get(name) not in (None, "")),
    }


async def update(
    kernel: Kernel, settings: Any, entry_id: str, values: dict[str, Any]
) -> dict[str, Any]:
    """保存界面填的值并重启插件；返回保存后的 :func:`view`。"""
    desc = description(kernel, entry_id)
    if not desc or "schema" not in desc:
        reason = (desc or {}).get("unsupported")
        if reason:
            raise BadRequestException(reason)
        raise BadRequestException(message_key="plugins.settings.notEditable")
    schema = desc["schema"]
    properties = schema["properties"]
    unknown = sorted(set(values) - set(properties))
    if unknown:
        raise BadRequestException(
            message_key="errors.plugins.unknownSettings",
            params={"fields": {"message_list": unknown, "separator_key": "common.list.separator"}},
        )
    secrets = secret_fields(schema)
    stored = settings_store.read(settings, entry_id)
    new = dict(stored)
    for name, value in values.items():
        if name in secrets and value in (None, ""):
            continue  # 敏感字段留空 = 不改
        new[name] = value
    base = dict((fiber.entry.config if (fiber := kernel.fiber(entry_id)) else None) or {})
    _validate(kernel, entry_id, schema, {**base, **new})

    before = settings_store.snapshot(settings, entry_id)
    settings_store.write(settings, entry_id, new, secrets)
    error = await _restart(kernel, entry_id)
    if error is not None:
        settings_store.restore(settings, entry_id, before)
        await _restart(kernel, entry_id)
        logger.warning("插件 %s 用新设置没能启动，已恢复原设置：%s", entry_id, error)
        raise BadRequestException(
            message_key="errors.plugins.settingsRolledBack", params={"error": error}
        )
    logger.info("插件 %s 的设置已保存并重启", entry_id)
    return view(kernel, settings, entry_id)


def _merged(kernel: Kernel, settings: Any, entry_id: str) -> dict[str, Any]:
    fiber = kernel.fiber(entry_id)
    base = dict((fiber.entry.config if fiber else None) or {})
    return {**base, **settings_store.read(settings, entry_id)}


def _validate(
    kernel: Kernel, entry_id: str, schema: dict[str, Any], config: dict[str, Any]
) -> None:
    """保存前用插件自己的配置模型校验；错误按字段、用中文报（字段名取 Schema 里的标题）。

    进程内插件直接校验；进程外插件另起子进程校验（主进程不导入插件代码）。
    """
    from movieclaw_api.services import plugin_runtime

    fiber = kernel.fiber(entry_id)
    errors: list[dict[str, Any]] = []
    if entry_id in plugin_runtime.process_specs:
        try:
            errors = plugin_runtime.validate_config(entry_id, config)
        except Exception as exc:  # noqa: BLE001 -- 校验跑不起来就交给重启兜底，不挡保存
            logger.warning("插件 %s 的设置没能预先校验：%s", entry_id, exc)
            return
    else:
        validate = getattr(fiber.plugin.config if fiber else None, "model_validate", None)
        if validate is None:
            return
        from pydantic import ValidationError

        try:
            validate(config)
        except ValidationError as exc:
            errors = exc.errors(include_url=False, include_input=False)
    if errors:
        raise BadRequestException(
            message_key="errors.plugins.settingsInvalid",
            params={"detail": error_references(errors, schema)},
        )


#: pydantic 错误类型 → 中文说明（取不到就用原文）
_MESSAGES = {
    "missing": "errors.validation.required",
    "greater_than_equal": "errors.validation.minimum",
    "greater_than": "errors.validation.greaterThan",
    "less_than_equal": "errors.validation.maximum",
    "less_than": "errors.validation.lessThan",
    "int_parsing": "errors.validation.integer",
    "int_type": "errors.validation.integer",
    "int_from_float": "errors.validation.integer",
    "float_parsing": "errors.validation.number",
    "float_type": "errors.validation.number",
    "bool_parsing": "errors.validation.boolean",
    "bool_type": "errors.validation.boolean",
    "string_type": "errors.validation.text",
    "string_too_short": "errors.validation.minLength",
    "string_too_long": "errors.validation.maxLength",
    "string_pattern_mismatch": "errors.validation.pattern",
    "enum": "errors.validation.allowedValues",
    "literal_error": "errors.validation.allowedValues",
    "list_type": "errors.validation.list",
}


def error_references(errors: list[dict[str, Any]], schema: dict[str, Any]) -> dict:
    properties = schema.get("properties") or {}
    parts = []
    for err in errors:
        loc = [str(p) for p in err.get("loc") or ()]
        field = loc[0] if loc else ""
        annotation = properties.get(field) or {}
        label = annotation.get("title") or field
        label_ref = (
            {"message_text": label, "message_localized": annotation.get("title_localized")}
            if label
            else reference("errors.validation.settings")
        )
        key = _MESSAGES.get(str(err.get("type")))
        try:
            reason = (
                reference(key, **(err.get("ctx") or {}))
                if key
                else err.get("msg") or reference("errors.validation.invalid")
            )
            render_value(reason)
        except (KeyError, IndexError):
            reason = err.get("msg") or reference("errors.validation.invalid")
        parts.append(reference("errors.validation.field", label=label_ref, reason=reason))
    return {"message_list": parts, "separator_key": "common.list.issueSeparator"}


def describe_errors(errors: list[dict[str, Any]], schema: dict[str, Any]) -> str:
    return render_value(error_references(errors, schema))


async def _restart(kernel: Kernel, entry_id: str) -> str | None:
    """让插件按新配置重新启动；返回失败原因（成功为 None）。用户停用中的插件只存不启。"""
    fiber = kernel.fiber(entry_id)
    if fiber is None:
        return t("errors.plugins.noLongerExists")
    if fiber.state is State.DISABLED and fiber.disabled_by not in (None, RESTART_SOURCE):
        return None
    await kernel.disable(entry_id, source=RESTART_SOURCE)
    await kernel.enable(entry_id)
    fiber = kernel.fiber(entry_id)
    if fiber is not None and fiber.state is State.FAILED:
        return fiber.error or t("errors.plugins.startupFailed")
    return None
