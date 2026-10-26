"""rename push_preference.events keys to the event names they follow

统一事件（docs/design/domain-events.md §6.1）：通知偏好的开关键改成触发它的事件名
（``imported`` → ``subscription.fulfilled`` …），插件的通知也按事件名登记，同一套键。

只改 JSON 里的键名；老 App 发来的旧键由服务端按别名接收（``preferences.LEGACY_KEYS``）。
回退到旧版本时旧代码读不到新键、按默认值算——只影响改过开关的人，可接受。

Revision ID: 5b8d2e6f1a47
Revises: e41a7c2f9b63
Create Date: 2026-10-12 11:00:00.000000

"""

import json
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "5b8d2e6f1a47"
down_revision: str | None = "e41a7c2f9b63"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RENAMES = {
    "imported": "subscription.fulfilled",
    "download_started": "subscription.download_started",
    "identity_skipped": "subscription.identity_skipped",
    "upgraded": "subscription.upgraded",
    "library_new": "library.items.arrived",
    "new_device": "account.device.signed_in",
    "system_alert": "system.alert.raised",
    "new_version": "system.update.available",
    "usage_tip": "system.tip.suggested",
}


def _rewrite(mapping: dict[str, str]) -> None:
    bind = op.get_bind()
    rows = bind.execute(sa.text("SELECT member_id, events FROM push_preference")).fetchall()
    for member_id, raw in rows:
        events = json.loads(raw) if isinstance(raw, str) else (raw or {})
        if not isinstance(events, dict):
            continue
        renamed = {mapping.get(k, k): v for k, v in events.items()}
        if renamed != events:
            bind.execute(
                sa.text("UPDATE push_preference SET events = :events WHERE member_id = :member"),
                {"events": json.dumps(renamed, ensure_ascii=False), "member": member_id},
            )


def upgrade() -> None:
    _rewrite(RENAMES)


def downgrade() -> None:
    _rewrite({new: old for old, new in RENAMES.items()})
