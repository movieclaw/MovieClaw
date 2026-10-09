"""随应用携带的插件包（docs/design/plugin-channels.md §7）。

每个子目录都是一个完整的插件包（带 ``movieclaw-plugin.toml``），与第三方插件包同一套清单：
代码只依赖 SDK（``movieclaw_sdk``）与开放契约，能原样打成 ``.mcplugin`` 动态安装。随应用携带时
作为内置插件加载（受信、主进程里运行）；装一个同 id 的插件包即替换它，卸载后随带版本回来。
"""
