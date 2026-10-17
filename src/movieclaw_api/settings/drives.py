"""网盘的全局选项（docs/design/cloud-storage.md §6.3）。

账号各自的限速、预算、同时播放数在账号上；这里只放跨账号的意愿开关。
"""

from __future__ import annotations

from pydantic import Field

from movieclaw_api.settings.base import SettingSchema, register_setting


@register_setting(namespace="drives.release", title="网盘")
class DriveReleaseSetting(SettingSchema):
    """库文件传到网盘、本地腾空之后的事。"""

    remove_download_tasks: bool = Field(
        default=True,
        description=(
            "本地腾空后删除对应的下载任务（连同下载目录里的数据），空间才真正回来。"
            "有 H&R 考核的种子、不是 MovieClaw 投递的种子、还供着库里其他本地文件的种子都保留"
        ),
    )
