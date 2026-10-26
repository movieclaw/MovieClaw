"""事件 Webhook（docs/design/webhook.md、domain-events.md §6.2）：每个地址是事件总线上的一个订阅方。

分层：
- ``catalog``    —— 能勾选的事件：就是系统事件目录（分组、说明、Jellyfin 对应物）；
- ``delivery``   —— 投递：按配置给每个地址订阅事件、拼报文、签名、发送；失败交给可靠事件重试；
- ``jellyfin_formatter`` / ``handlebars`` —— Jellyfin 兼容格式（用户粘贴的模板）；
- ``deliveries`` —— 投递记录：每个地址一个内存环形缓冲（诊断用途）。

新增系统事件不用改这里：在 ``movieclaw_sdk.events`` 定义、产生点 ``publish`` 一次，设置页就能勾。
"""

from movieclaw_api.services.webhook.catalog import catalog_view
from movieclaw_api.services.webhook.deliveries import recent_deliveries
from movieclaw_api.services.webhook.delivery import deliver_test, resync

__all__ = ["catalog_view", "deliver_test", "recent_deliveries", "resync"]
