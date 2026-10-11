"""add llm_provider.api_protocol: 实例可选 Chat Completions / Responses API

GPT-5.6 在 Chat Completions 上不允许函数工具与思考强度同时出现（issue
#768），OpenAI 预设默认协议改为 Responses API；可自填端点的实例（OpenAI
配镜像端点、通用兼容端点）可在两种协议间切换。NULL = 跟随预设默认。

回填：OpenAI 预设下填了第三方 base_url 的存量实例固定为 openai_chat——
中转站未必支持 /v1/responses，升级后不能让它们悄悄换协议后调不通；
官方端点（未填或填 api.openai.com）保持 NULL，随预设切到 Responses。

顺带修正：gpt-5.6-luna 实测不支持 max 档位（同一 issue），预设已删；但兼容
端点「借用」目录模型时把参数复制进了 extra_models，存量副本里的 max 也要删，
否则选了「最高」照样 400。

Revision ID: 9378b238ae54
Revises: 10b695b1836a
Create Date: 2026-10-11 10:00:00.000000

"""

from __future__ import annotations

import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "9378b238ae54"
down_revision: str | None = "10b695b1836a"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table("llm_provider", schema=None) as batch_op:
        batch_op.add_column(sa.Column("api_protocol", sa.String(), nullable=True))
    op.execute(
        "UPDATE llm_provider SET api_protocol = 'openai_chat' "
        "WHERE provider_type = 'openai' AND base_url IS NOT NULL "
        "AND base_url NOT LIKE 'https://api.openai.com%'"
    )
    _drop_luna_max_level()


def _drop_luna_max_level() -> None:
    """删掉 extra_models 里 gpt-5.6-luna 副本声明的 max 档位。"""
    bind = op.get_bind()
    rows = bind.execute(
        sa.text("SELECT id, extra_models FROM llm_provider WHERE extra_models IS NOT NULL")
    ).fetchall()
    for row_id, raw in rows:
        models = json.loads(raw) if isinstance(raw, str) else raw
        changed = False
        for model in models or []:
            control = model.get("thinking_control") or {}
            levels = control.get("levels") or []
            if model.get("id") == "gpt-5.6-luna" and "max" in levels:
                control["levels"] = [level for level in levels if level != "max"]
                changed = True
        if changed:
            bind.execute(
                sa.text("UPDATE llm_provider SET extra_models = :models WHERE id = :id"),
                {"models": json.dumps(models, ensure_ascii=False), "id": row_id},
            )


def downgrade() -> None:
    # luna 副本删掉的 max 不回填：那是错误声明，旧代码少一个必然 400 的档位无害
    with op.batch_alter_table("llm_provider", schema=None) as batch_op:
        batch_op.drop_column("api_protocol")
