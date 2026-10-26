# dmgbuild 的布局配置（package-mac-app.sh 调用）：打开 DMG 就是
# 「左边 App、右边应用程序、中间箭头」的拖拽窗口。
# 由 dmgbuild 直接写 .DS_Store，不经 Finder 和 AppleScript，流水线上没有图形会话也能排好版。
# 传入（-D）：app=.app 路径，background=多分辨率 TIFF，icon=卷图标（App 的 AppIcon.icns）。
# 坐标与 make-background.swift 的画布对应（600×400 点，左上角为原点，图标给的是中心点）。
import os.path

# dmgbuild 执行这个文件时注入 defines
app = defines["app"]  # noqa: F821
app_name = os.path.basename(app)

format = "ULMO"  # LZMA 压缩，macOS 10.15 起都能打开
filesystem = "HFS+"
files = [app]
# 替身不会像真正的「应用程序」文件夹那样按系统语言显示，只能定一个名字：App 支持中英两种语言，
# 用英文的系统原名；背景图上的说明中英各一行
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821
hide_extension = [app_name]

window_rect = ((200, 160), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {app_name: (150, 190), "Applications": (450, 190)}
