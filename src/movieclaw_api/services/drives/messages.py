"""MovieClaw 自己抛出的网盘错误：带消息键（接口按读者语言渲染），``message`` 是中文原文。

插件报来的错误只有原话，原样透传。
"""

from movieclaw_api.i18n.stored import exception_reference as error_reference
from movieclaw_api.i18n.stored import keyed_error as keyed

__all__ = ["error_reference", "keyed"]
