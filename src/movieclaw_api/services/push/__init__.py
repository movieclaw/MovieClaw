"""App 推送（docs/design/cloud-push.md）。

分层：

- ``crypto``       —— 密文格式与 collapse_id（push-payload.md）；
- ``relay``        —— 推送中继协议客户端（/v1/info、/v1/push）；
- ``channels``     —— 推送通道（官方 + 自建中继）、路由、运行期状态；
- ``registration`` —— App 的推送登记（存在 login_device 行上）；
- ``preferences``  —— 事件目录与个人偏好；
- ``notify``       —— 事件 → 每个人、每台手机的加密推送；
- ``dispatcher``   —— 选通道、发送、处理结果、重试；
- ``events``       —— 业务产生点调用的入口（入库、开始下载、洗版、新设备、待处理事项）；
- ``images``       —— 推送配图的签名地址；
- ``admin`` / ``me`` —— 设置页的后端。
"""
