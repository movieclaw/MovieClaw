#!/usr/bin/env python3
"""dex2oat/ffmpeg fork ohdec.c 补丁：修复 HISI 10-bit 硬解 buffer 花屏。

背景（真机 2026-10-30 定位，嫁金钗 3840x2160@60 10-bit HEVC）：
  1. buffer 模式在 Configure 时请求 NV12（oh_decode_set_format），HISI 对 10-bit
     流仍输出 P010 内存（HCODEC 统计 out≈11.5Gbps@60fps ≈ 24MB/帧 = 4K P010），
     且 PIXEL_FORMAT 仍上报 NV12 —— oh_decode_wrap_sw_buffer 按 NV12 拷贝：
     UV 偏移读错 + Y 平面只读一半 → 画面严重花屏。
  2. on_stream_changed / wrap_sw_buffer 成功路径全程零日志，出问题无法定位。

本补丁（幂等，重复执行无副作用）：
  A. oh_decode_on_stream_changed：AV_LOG_WARNING 打印协商出的
     width/height/stride/slice_height/pix_fmt（warn 能穿过 mpv client log level，
     app 侧 mpv_napi.cpp 已把 warn 转发到 hilog）。
   B. oh_decode_wrap_sw_buffer：按 buffer capacity / stride 检测真实 10-bit P010
      布局；命中且帧格式为 NV12 时做 P010→NV12 向量化降位拷贝（uint16 连续读+
      常量移位，标量字节版 ~10ms/帧会造成 A/V desync 抽帧；自动探测 10-bit 数据
      在高/低字节），并打一次性布局日志；8-bit 走原拷贝路径不变。
  C. P010 已如实上报、stride 为字节数的组合（部分厂商行为）用显式逐行 memcpy 兜底
     （原实现按像素 stride 翻倍 linesize 会越界）。

用法：apply-ffmpeg-patch.py <libavcodec/ohdec.c>
"""
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

if "MovieClaw ohdec patch" in src:
    print("ohdec patch: 已打过补丁")
    sys.exit(0)

orig = src

# --- include：pixdesc（av_get_pix_fmt_name）---
src = src.replace(
    '#include "libavutil/imgutils.h"\n',
    '#include "libavutil/imgutils.h"\n'
    '#include "libavutil/pixdesc.h"\n')

# --- struct：布局诊断字段 ---
src = src.replace(
    """    int stride;
    int slice_height;
    OH_AVPixelFormat pix_fmt;
""",
    """    int stride;
    int slice_height;
    OH_AVPixelFormat pix_fmt;

    /* MovieClaw ohdec patch: buffer layout diagnostics (HISI 10-bit) */
    bool layout_logged;
    int tenbit_lane;
""")

# --- on_stream_changed：参数日志 + 重置一次性日志标志 ---
src = src.replace(
    """    s->got_stream_info = true;

    return;
""",
    """    /* MovieClaw ohdec patch: warn 级别打印协商布局（穿过 mpv client log level）*/
    av_log(avctx, AV_LOG_WARNING,
           "ohdec stream: %dx%d stride=%d slice_height=%d pix_fmt=%d -> %s\\n",
           s->width, s->height, s->stride, s->slice_height,
           (int)s->pix_fmt, av_get_pix_fmt_name(avctx->pix_fmt));
    s->layout_logged = false;

    s->got_stream_info = true;

    return;
""")

# --- wrap_sw_buffer：10-bit P010 布局自适应拷贝 ---
src = src.replace(
    """    uint8_t *src[4] = {0};
    int src_linesizes[4] = {0};

    ret = av_image_fill_linesizes(src_linesizes, frame->format, s->stride);
    if (ret < 0)
        return ret;
    ret = av_image_fill_pointers(src, frame->format, s->slice_height, p,
                                 src_linesizes);
    if (ret < 0)
        return ret;
    av_image_copy2(frame->data, frame->linesize, src, src_linesizes,
                   frame->format, frame->width, frame->height);
""",
    """    /* MovieClaw ohdec patch: HiSilicon 解码器对 10-bit 流忽略 NV12 请求：
     * 写入 P010 内存却仍上报 NV12。原 NV12 拷贝会读错 UV 偏移、只读半个
     * Y 平面 → 花屏。按 capacity/stride 检测真实布局，10-bit 时做
     * P010→NV12 降位拷贝，并打一次性布局日志。
     */
    int32_t capacity = OH_AVBuffer_GetCapacity(output->buffer);
    int64_t nv12_bytes = (int64_t)s->stride * s->slice_height * 3 / 2;
    bool ten_bit_memory = capacity > nv12_bytes * 7 / 4 ||
                          s->stride >= avctx->width * 2;

    if (ten_bit_memory && frame->format == AV_PIX_FMT_NV12) {
        int bstride = s->stride >= avctx->width * 2
                          ? s->stride : s->stride * 2;
        if (!s->layout_logged) {
            /* P010 规范：16-bit 小端、10-bit 值在高 6 位 —— 低字节恒为
             * (pixel&3)<<6 ∈ {0,64,128,192}（64 的倍数）。用这个不变量判方向：
             * 低字节全是 64 的倍数 → 标准布局，取高字节（lane=1）。
             * （动态范围法在暗场不可靠：高字节=内容>>2 可低至 ~47，
             *   低字节模式值恒达 192，会被误判反向 → 全屏花屏，Pura X 实测。） */
            int v64viol = 0;
            int scan = FFMIN(bstride, 2048);
            for (int i = 0; i + 1 < scan; i += 2) {
                if ((p[i] & 63) != 0)
                    v64viol++;
            }
            s->tenbit_lane = v64viol == 0 ? 1 : 0;
            s->layout_logged = true;
            av_log(avctx, AV_LOG_WARNING,
                   "ohdec: 10-bit buffer as NV12: %dx%d stride=%d "
                   "slice_height=%d cap=%d size=%d nv12_min=%lld lane=%d "
                   "(v64viol=%d) -> P010->NV12 downconvert\\n",
                   s->width, s->height, s->stride, s->slice_height,
                   (int)capacity, (int)attr->size,
                   (long long)nv12_bytes, s->tenbit_lane, v64viol);
        }
        int lane = s->tenbit_lane;
        const uint8_t *ysrc = p;
        const uint8_t *uvsrc = p + (int64_t)bstride * s->slice_height;
        /* P010→NV12 降位：每帧 12.4M 次采样。标量 ldrb/strb ≈18ms/帧，
         * 60fps 预算 16.6ms → 解码线程跟不上 → A/V desync 抽帧（Pura X 实测）。
         * 向量化两个关键点（本文件 v64viol 扫描循环对照实证）：
         *   1) 循环边界/目标指针必须先提升为局部量：frame->data[0] 的存储
         *      可能别名 frame->width，编译器无法证明不变 → 内层循环每迭代
         *      重载 width（实测 ldrsw [x25,#104]）→ 向量化器放弃；
         *   2) 常量移位被 instcombine 折成高字节直读（u16>>8 → ldrb[+1]），
         *      单跨步访问由 interleaved-access 降为 ld2 解交错（扫描循环
         *      同款形态已验证）。hoist 后 width 进寄存器，向量化器只需
         *      src/dst 运行时别名检查即生成 ld2 + st1。 */
        const int width = frame->width;
        const int height = frame->height;
        const int uv_height = (height + 1) / 2;
        uint8_t *const dst_y = frame->data[0];
        uint8_t *const dst_uv = frame->data[1];
        const int dst_ystride = frame->linesize[0];
        const int dst_uvstride = frame->linesize[1];
        if ((bstride & 1) == 0) {
            const uint16_t *y16 = (const uint16_t *)(const void *)ysrc;
            const uint16_t *uv16 = (const uint16_t *)(const void *)uvsrc;
            if (lane) {
                for (int y = 0; y < height; y++) {
                    const uint16_t *s16 = y16 + (int64_t)y * (bstride / 2);
                    uint8_t *drow = dst_y + (int64_t)y * dst_ystride;
                    for (int x = 0; x < width; x++)
                        drow[x] = (uint8_t)(s16[x] >> 8);
                }
                for (int y = 0; y < uv_height; y++) {
                    const uint16_t *s16 = uv16 + (int64_t)y * (bstride / 2);
                    uint8_t *drow = dst_uv + (int64_t)y * dst_uvstride;
                    for (int x = 0; x < width; x++)
                        drow[x] = (uint8_t)(s16[x] >> 8);
                }
            } else {
                for (int y = 0; y < height; y++) {
                    const uint16_t *s16 = y16 + (int64_t)y * (bstride / 2);
                    uint8_t *drow = dst_y + (int64_t)y * dst_ystride;
                    for (int x = 0; x < width; x++)
                        drow[x] = (uint8_t)s16[x];
                }
                for (int y = 0; y < uv_height; y++) {
                    const uint16_t *s16 = uv16 + (int64_t)y * (bstride / 2);
                    uint8_t *drow = dst_uv + (int64_t)y * dst_uvstride;
                    for (int x = 0; x < width; x++)
                        drow[x] = (uint8_t)s16[x];
                }
            }
        } else {
            /* bstride 奇数（理论上不会发生）：安全字节版 */
            for (int y = 0; y < height; y++) {
                const uint8_t *srow = ysrc + (int64_t)y * bstride;
                uint8_t *drow = dst_y + (int64_t)y * dst_ystride;
                for (int x = 0; x < width; x++)
                    drow[x] = srow[2 * x + lane];
            }
            for (int y = 0; y < uv_height; y++) {
                const uint8_t *srow = uvsrc + (int64_t)y * bstride;
                uint8_t *drow = dst_uv + (int64_t)y * dst_uvstride;
                for (int x = 0; x < width; x++)
                    drow[x] = srow[2 * x + lane];
            }
        }
    } else if (frame->format == AV_PIX_FMT_P010 &&
               s->stride >= avctx->width * 2) {
        /* P010 已如实上报、stride 为字节数：逐行 memcpy（原实现会按像素
         * stride 把 linesize 翻倍导致越界/花屏）。 */
        if (!s->layout_logged) {
            s->layout_logged = true;
            av_log(avctx, AV_LOG_WARNING,
                   "ohdec: P010 with byte stride: %dx%d stride=%d "
                   "slice_height=%d cap=%d size=%d\\n",
                   s->width, s->height, s->stride, s->slice_height,
                   (int)capacity, (int)attr->size);
        }
        int bstride = s->stride;
        const uint8_t *uvsrc = p + (int64_t)bstride * s->slice_height;
        for (int y = 0; y < frame->height; y++)
            memcpy(frame->data[0] + (int64_t)y * frame->linesize[0],
                   p + (int64_t)y * bstride, frame->width * 2);
        for (int y = 0; y < (frame->height + 1) / 2; y++)
            memcpy(frame->data[1] + (int64_t)y * frame->linesize[1],
                   uvsrc + (int64_t)y * bstride, frame->width * 2);
    } else {
        if (!s->layout_logged) {
            s->layout_logged = true;
            av_log(avctx, AV_LOG_WARNING,
                   "ohdec: 8-bit buffer: %dx%d stride=%d slice_height=%d "
                   "cap=%d size=%d nv12_min=%lld fmt=%s\\n",
                   s->width, s->height, s->stride, s->slice_height,
                   (int)capacity, (int)attr->size,
                   (long long)nv12_bytes,
                   av_get_pix_fmt_name(frame->format));
        }
        uint8_t *src[4] = {0};
        int src_linesizes[4] = {0};

        ret = av_image_fill_linesizes(src_linesizes, frame->format, s->stride);
        if (ret < 0)
            return ret;
        ret = av_image_fill_pointers(src, frame->format, s->slice_height, p,
                                     src_linesizes);
        if (ret < 0)
            return ret;
        av_image_copy2(frame->data, frame->linesize, src, src_linesizes,
                       frame->format, frame->width, frame->height);
    }
""")

if src == orig:
    raise SystemExit("ohdec patch: 目标代码段未找到（ohdec.c 版本不匹配？）")

for marker in ("MovieClaw ohdec patch", "P010->NV12 downconvert",
               "layout_logged", "tenbit_lane"):
    assert marker in src, f"patch 后缺少 {marker}"
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("ohdec patch: HISI 10-bit P010 修正 + 布局日志 已应用")
