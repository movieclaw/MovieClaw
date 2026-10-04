import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// 共享层里少数要碰原生视图 / 位图的地方（播放画面的宿主、进度条缩略图、锁屏封面）在 iPhone、Apple TV 上是 UIKit，
// 在 Mac 上是 AppKit。这里只起两个中性的名字，各处按它写一份代码；真正行为不同的地方仍在原处用 #if 分开。
// 不叫 PlatformImage：Nuke 已经导出了同名类型，同名会让读代码的人分不清是哪一个。

#if canImport(UIKit)
/// 原生位图：UIImage / NSImage
typealias NativeImage = UIImage
/// 原生视图：UIView / NSView
typealias NativeView = UIView
#else
typealias NativeImage = NSImage
typealias NativeView = NSView

extension NSImage {
    /// 与 UIImage(cgImage:) 同用法：按位图像素尺寸建图
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 与 UIImage.cgImage 同用法
    var cgImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#endif

extension Image {
    /// 用原生位图建 SwiftUI 图
    init(native image: NativeImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}
