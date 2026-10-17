"""retry fingerprints that failed on an undecodable first audio track

片头片尾识别原先只用第一条音轨（时长不足才换轨）。华语 WEB-DL 常把 Audio Vivid（AV3A）
放第一轨，ffmpeg 没有解码器，指纹记成失败、整季识别不了；失败的行除非片源变了不会重算。
新版改用同语言、解得了的音轨，这里把这类失败排回待办，让回填重算一次。

只动「音频解码失败」开头的失败行：其他原因（没音轨、读不到、太短）换版本也算不出来。
新版对解不了又换不了轨的文件报的是另一条原因，不会被下次升级再排回来。

Revision ID: c4a7e9d2f613
Revises: 9f3c6a2e1b58
Create Date: 2026-10-17 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c4a7e9d2f613"
down_revision: str | None = "9f3c6a2e1b58"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.get_bind().execute(
        sa.text(
            "UPDATE media_segment SET fingerprint_status = 'pending', error = NULL "
            "WHERE fingerprint_status = 'failed' AND error LIKE '音频解码失败%'"
        )
    )


def downgrade() -> None:
    # 排回待办的行由旧版照常重算（再失败就再记失败），无需还原
    pass
