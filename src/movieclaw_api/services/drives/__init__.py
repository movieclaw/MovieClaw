"""网盘存储层（docs/design/cloud-storage.md）。

- ``registry``：注册表 ``drive-backends`` 的绑定，按类型找后端；
- ``gateway``：对后端的每次调用都经这里（超时、按账号限速与每日预算、错误归类、凭据先落库）；
- ``accounts``：网盘账号（扫码登录、Cookie 导入、设置、删除）。
"""
