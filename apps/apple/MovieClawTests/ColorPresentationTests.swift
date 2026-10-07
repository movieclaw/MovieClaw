import CoreVideo
import Testing
import AetherLibavutil
@testable import AetherEngine
import AetherCore

/// SDR 按 sRGB 上屏（引擎补丁 P60）：iPhone / Mac 上 BT.709 曲线的 SDR（含未标注）改标 sRGB，
/// HDR 与其他传递函数不动；原色、矩阵的缺省补全仍同 VideoToolbox（AE#654）。
struct ColorPresentationTests {
    /// 引擎默认按上游显示；MovieClaw 的配置（AetherCore）打开 P60
    init() { AetherPlayback.configureEngine() }

    private func describe(p: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
                          t: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
                          m: AVColorSpace = AVCOL_SPC_UNSPECIFIED) -> ColorDescription {
        ColorDescription(primaries: p, transfer: t, matrix: m, range: AVCOL_RANGE_UNSPECIFIED)
    }

    @Test func sdrGoesOutAsSRGB() {
        #expect(ColorAttachments.presentsSDRAsSRGB)
        let srgb = kCVImageBufferTransferFunction_sRGB
        let untagged = ColorAttachments.presented(describe())
        #expect(untagged == .init(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, transfer: srgb,
                                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        #expect(ColorAttachments.presented(describe(p: AVCOL_PRI_BT709, t: AVCOL_TRC_BT709, m: AVCOL_SPC_BT709)).transfer == srgb)
        #expect(ColorAttachments.presented(describe(t: AVCOL_TRC_SMPTE170M)).transfer == srgb)
        #expect(ColorAttachments.presented(describe(t: AVCOL_TRC_BT2020_10)).transfer == srgb)
        #expect(ColorAttachments.shownTransfer(nil) == srgb)
        #expect(ColorAttachments.shownTransfer(kCVImageBufferTransferFunction_ITU_R_709_2) == srgb)
    }

    @Test func hdrAndOtherCurvesKeepTheirTag() {
        // 硬解通路按 VideoToolbox 从 VUI 读出的标签判断：HDR 与其他曲线原样
        for tag in [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    kCVImageBufferTransferFunction_Linear, kCVImageBufferTransferFunction_sRGB] {
            #expect(ColorAttachments.shownTransfer(tag) == tag)
        }
        #expect(ColorAttachments.presented(describe(t: AVCOL_TRC_SMPTE2084)).transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    }

    @Test func gapsFilledAsVideoToolbox() {
        let lone601 = ColorAttachments.presented(describe(m: AVCOL_SPC_SMPTE170M))
        #expect(lone601.primaries == kCVImageBufferColorPrimaries_SMPTE_C)
        #expect(lone601.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let pal = ColorAttachments.presented(describe(p: AVCOL_PRI_BT470BG))
        #expect(pal.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let wide = ColorAttachments.filled(describe(p: AVCOL_PRI_BT2020))
        #expect(wide.matrix == AVCOL_SPC_BT2020_NCL)
        // CoreVideo 叫不出名字的原色按缺省处理，colr 里写的与显示层拿到的一致
        let film = ColorAttachments.filled(describe(p: AVCOL_PRI_FILM, m: AVCOL_SPC_SMPTE170M))
        #expect(film.primaries == AVCOL_PRI_SMPTE170M)
    }
}
