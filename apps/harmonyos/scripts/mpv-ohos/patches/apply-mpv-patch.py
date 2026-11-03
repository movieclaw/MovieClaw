#!/usr/bin/env python3
"""dex2oat/mpv fork 有几处漏提交/引用错误，按目标文件分别修复：

meson.build：
  1. ohos sources 引用了仓库里不存在的 video/out/vo_ohcodec.c —— 移除
  2. ohos-osd-overlay 块引用了不存在的 vo_ohcodec_osd.c —— 整块移除
  （保留 vo_gpu + --gpu-context=ohos(EGL) + hwdec=ohcodec 这条经过验证的路径）

options/options.h：
  3. options.c:252 注册了 ohos-surface-size 选项、ohos_common.c:91 在读
     vo->opts->ohos_surface_size，但 mp_vo_opts 结构体里没这个成员（fork 漏提交）—— 补上

幂等：重复执行无副作用。用法：apply-mpv-patch.py <meson.build|options.h>
"""
import re
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()
orig = src

if path.endswith("meson.build"):
    # 1) ohos sources: 去掉 vo_ohcodec.c
    src = src.replace(
        """                     'video/out/hwdec/hwdec_ohcodec.c',
                     'video/out/vo_ohcodec.c')""",
        """                     'video/out/hwdec/hwdec_ohcodec.c')""")
    # 2) 删除 ohos-osd-overlay 块（从注释行到配对的 endif）
    src = re.sub(r"\n *# OSD overlay support for vo_ohcodec.*?endif\n", "\n", src, flags=re.S)
    if src == orig:
        print("meson patch: 无变化（已打过补丁）")
    else:
        for missing in ("vo_ohcodec.c", "vo_ohcodec_osd.c"):
            assert missing not in src, f"patch 后仍引用 {missing}"
        with open(path, "w") as f:
            f.write(src)
        print("meson patch: 已移除 vo_ohcodec.c / ohos-osd-overlay 引用")
elif path.endswith("ohos_common.c"):
    # 4) fork 的 vo_ohos_ohcodec_discard() 调用 ff_ohcodec_discard_buffer()，
    #    但配套的 FFmpeg fork 里没有这个符号（两个 fork 版本错位）→ libmpv.so 加载时
    #    relocation 失败。该函数只服务 vo_ohcodec surface 模式的高倍速丢帧，
    #    GL 输出路径用不到 —— 改成安全 no-op。
    src = src.replace(
        "    ff_ohcodec_discard_buffer(mpi->planes[3]);",
        """    // MovieClaw patch: ff_ohcodec_discard_buffer 在配套 FFmpeg fork 中不存在
    // （版本错位）。surface 模式高倍速丢帧用不上（GL 路径），安全 no-op。
    (void)mpi;""")
    if src == orig:
        print("ohos_common patch: 无变化（已打过补丁）")
    else:
        assert "ff_ohcodec_discard_buffer(mpi->planes[3])" not in src, "patch: 丢弃调用未移除"
        with open(path, "w") as f:
            f.write(src)
        print("ohos_common patch: vo_ohos_ohcodec_discard 已改为 no-op")
elif path.endswith("vo.c"):
    # 5) vo.c 的驱动表挂着 video_out_ohcodec / _osd（定义文件 vo_ohcodec*.c 没提交），
    #    HAVE_OHOS 打开时链接出的 libmpv.so 加载即 relocation 失败 —— 移除引用。
    src = src.replace("extern const struct vo_driver video_out_ohcodec;\n", "")
    src = src.replace("extern const struct vo_driver video_out_ohcodec_osd;\n", "")
    src = src.replace(
        """#if HAVE_OHOS
#if HAVE_OHOS_OSD_OVERLAY
    &video_out_ohcodec_osd,
#endif
    &video_out_ohcodec,
#endif
""",
        """#if HAVE_OHOS
#endif
""")
    if src == orig:
        print("vo.c patch: 无变化（已打过补丁）")
    else:
        assert "video_out_ohcodec" not in src, "patch: vo.c 仍引用 ohcodec 驱动"
        with open(path, "w") as f:
            f.write(src)
        print("vo.c patch: 已移除 video_out_ohcodec 驱动注册")
elif path.endswith("options.h"):
    src = src.replace(
        """    struct m_geometry d3d11_composition_size;

    int swapchain_depth;  // max number of images to render ahead""",
        """    struct m_geometry d3d11_composition_size;

    // MovieClaw patch: fork 引用了但没提交的成员（ohos-surface-size 选项）
    struct m_geometry ohos_surface_size;

    int swapchain_depth;  // max number of images to render ahead""")
    if src == orig:
        print("options.h patch: 无变化（已打过补丁）")
    else:
        assert "ohos_surface_size;" in src, "patch: ohos_surface_size 成员未补上"
        with open(path, "w") as f:
            f.write(src)
        print("options.h patch: 已补上 mp_vo_opts.ohos_surface_size 成员")
else:
    raise SystemExit(f"未知目标文件: {path}")
