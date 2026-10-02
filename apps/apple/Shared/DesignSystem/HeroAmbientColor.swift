import Nuke
import SwiftUI
import UIKit

// 大图主色：iPhone（订阅首页、发现页的沉浸 Hero）与 Apple TV（首页大图区）共用同一套取色，
// 两端页面底色的观感才一致。

/// 从剧照里取一个「能当底色」的主色：按饱和度加权求色相（灰黑白不参与），
/// 亮度统一压到深色档，保证上面的白字永远读得清。结果按地址缓存，轮播回到同一张不再计算。
@MainActor
enum ImmersiveHeroAmbientColor {
    private static var cache: [URL: Color] = [:]

    static func color(for url: URL) async -> Color? {
        if let cached = cache[url] { return cached }
        // 与 Hero 显示同一个地址：命中 Nuke 的内存 / 磁盘缓存，不会重复下载
        guard let image = try? await ImagePipeline.shared.image(for: url) else { return nil }
        let color = await Task.detached(priority: .utility) { dominant(of: image) }.value
        cache[url] = color
        return color
    }

    /// 缩到 24×24 取样：每个像素按「饱和度² ×（亮度 + 0.25）」加权，色相按单位圆求平均（避免红色 0/1 两端相消）
    nonisolated static func dominant(of image: UIImage) -> Color {
        let side = 24
        guard let cgImage = image.cgImage,
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return fallback }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return fallback }

        var x = 0.0, y = 0.0, saturation = 0.0, weightSum = 0.0
        for index in 0 ..< side * side {
            let r = Double(data[index * 4]) / 255, g = Double(data[index * 4 + 1]) / 255, b = Double(data[index * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let value = maxC
            let delta = maxC - minC
            guard value > 0.12, delta > 0.04 else { continue }
            let s = delta / maxC
            var hue: Double
            if maxC == r { hue = (g - b) / delta } else if maxC == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
            hue /= 6
            if hue < 0 { hue += 1 }
            let weight = s * s * (value + 0.25)
            x += cos(hue * 2 * .pi) * weight
            y += sin(hue * 2 * .pi) * weight
            saturation += s * weight
            weightSum += weight
        }
        guard weightSum > 2 else { return fallback }
        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let meanSaturation = saturation / weightSum
        return Color(hue: hue, saturation: min(0.72, max(0.28, meanSaturation * 1.1)), brightness: 0.44)
    }

    /// 灰调剧照（黑白片、夜景）：冷银灰，与 App 的银色强调色同一家族
    nonisolated static let fallback = Color(hue: 0.61, saturation: 0.14, brightness: 0.36)
}
