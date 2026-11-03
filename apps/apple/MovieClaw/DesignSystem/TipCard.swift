import SwiftUI

/// 内联的使用提示卡（版式照 TipKit 的 TipView：左边图标、标题加一句说明、右上角关闭）。
/// 什么时候出现、关掉之后怎么记，由页面按 `TipsStore` 判定与上报（docs/design/tips.md）
struct TipCard: View {
    let systemImage: String
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 2.5)))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Theme.text)
                Text(message).font(.subheadline).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: .commonClose))
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }
}
