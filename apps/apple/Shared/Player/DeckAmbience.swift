import SwiftUI

/// 控制台底下的氛围背景：这一集的剧照（电影是海报）放大、重度模糊、提饱和、压暗，铺满折痕以下——
/// 控制台跟着片子换颜色，玻璃卡片也有东西可折射（同 Apple TV、Netflix 播放页的氛围色做法）。
/// 取很小的一张图（宽 120 点档）再模糊：图是静态的，合成一次就不再变，没有逐帧开销
struct DeckAmbience: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            if let url {
                // 图挂在一个不占尺寸的框上：图片自带的尺寸不能参与布局，否则整块控制台会被撑出屏幕（内屏实测）
                Color.clear
                    .overlay {
                        RemoteImage(url: url)
                            .scaleEffect(1.4)
                            .blur(radius: 40)
                            .saturation(1.5)
                            .opacity(0.55)
                    }
            }
            // 上缘淡进黑色：和折痕、上半屏画面的黑边接上，不出现一条硬边
            LinearGradient(colors: [.black, .black.opacity(0.2), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
