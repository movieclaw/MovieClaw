import SwiftUI
import UIKit

/// 全 App 的开关统一用系统自己的颜色（打开是系统绿）。
///
/// 全局 tint 是冷银（近白），开关跟着它走的话，打开和关闭几乎看不出区别。这个样式在 App 最外层设一次
/// （见 MovieClawApp），所有页面、弹出的面板里的开关都生效；样式里自己定颜色，外面再加的 `.tint` 盖不过它
struct SystemSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(Color(uiColor: .systemGreen))
    }
}
