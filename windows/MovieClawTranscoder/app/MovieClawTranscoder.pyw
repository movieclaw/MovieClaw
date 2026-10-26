"""MovieClaw 转码器的启动脚本（安装包里的入口）。

把两个包都放上导入路径后拉起应用外壳：``movieclaw_transcoder_app``（界面与编排）与
``movieclaw_transcoder``（转码内核）。仓库里两者一内一外（``app/`` 与同级目录），
安装包里 build-app.ps1 把两者都放进 ``app/``——两处都加，哪种布局都能跑。
用 pythonw.exe 跑它就没有控制台窗口；开始菜单快捷方式、开机自启都指向它。
"""

import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
for _path in (os.path.join(_here, "app"), _here):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from movieclaw_transcoder_app import main  # noqa: E402

sys.exit(main())
