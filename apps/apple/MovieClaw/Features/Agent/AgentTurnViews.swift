import NukeUI
import SwiftUI

// 会话时间线里一轮的各个组成部分（对应 Web `agent-conversation-view.tsx` 的 TurnView 及其子组件）。
// 消息列按段落级的行懒加载（见 AgentTranscriptRows），这里只提供每一行用到的组件。
//
// 呈现取舍（个人助理式的气泡卡片，与 Web 的整栏正文不同）：
// - 用户消息右侧 logo 蓝紫渐变气泡；Agent 的每段正文是左侧深灰气泡，生成式 UI 卡片组是独立卡片——颜色一眼分清谁说的；
// - 思考与工具调用收进「处理过程」小胶囊：进行中显示实时状态，完成后一句话总结；展开后工具调用
//   只列单行摘要，点某一行才展开参数与输出——一轮动辄十几次调用，全量平铺等于没有排版；
// - 进行中是三点气泡；跑完不出耗时，只在停止/中断时留一行小字，模型/token 这些排查信息不上屏。

/// 本轮以错误收尾时的红色提示卡片
struct AgentTurnErrorView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.danger.opacity(0.1), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.danger.opacity(0.3)))
            .textSelection(.enabled)
            .accessibilityIdentifier("agent-turn-error")
    }
}

// MARK: - 气泡

/// 会话气泡的配色与形状
enum AgentBubbleStyle {
    /// 用户（提问气泡、发送键）：取自 logo 渐变中段的蓝 → 紫（#4C9DFF → #9A6BFF 各压深一档，白字对比度 ≥ 4.5:1）。
    /// 先后否决过系统鲜蓝（暗色里刺眼）与雾蓝 #4B5F82（不好看），2026-10-12 用户要求从 logo 里取色
    static let userFill = LinearGradient(
        colors: [Color(red: 0x2F / 255, green: 0x6B / 255, blue: 0xD8 / 255), Color(red: 0x6A / 255, green: 0x4B / 255, blue: 0xD8 / 255)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    /// 助手（正文气泡、卡片组）：黑底上抬一档的深灰
    static let assistantFill = Color(white: 0.14)
    static let radius: CGFloat = 20
    static let paddingH: CGFloat = 16
    static let paddingV: CGFloat = 12
    /// 助手气泡右侧留白：气泡不贴满整行，左右两侧的归属一眼可辨
    static let assistantTrailingInset: CGFloat = 24

    static func shape(top: Bool = true, bottom: Bool = true) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0,
            topTrailingRadius: top ? radius : 0,
            style: .continuous
        )
    }
}

/// 助手正文气泡的一截（见 AgentTranscriptRow.Bubble）：首截上圆角、末截下圆角，块间距画在底色里；
/// 长按出原生菜单复制整段正文。超长正文才会拆成多截：长按时预览整个气泡（只在长按时把整段重新排一次版），
/// 否则浮起来的只是按到的那一截，看着像几个不同的气泡
struct AgentAnswerBubbleSlice<Content: View>: View {
    let bubble: AgentTranscriptRow.Bubble
    @ViewBuilder let content: Content
    /// 气泡宽度：整气泡预览按它排版，与列表里的气泡同宽
    @State private var width: CGFloat = 0

    var body: some View {
        let shape = AgentBubbleStyle.shape(top: bubble.first, bottom: bubble.last)
        let menu = Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = bubble.text }
        Group {
            if bubble.first && bubble.last {
                sliced.contentShape(.contextMenuPreview, shape).contextMenu { menu }
            } else {
                sliced.contextMenu { menu } preview: { AgentAnswerBubblePreview(text: bubble.text, width: width) }
            }
        }
        .accessibilityIdentifier("agent-answer-bubble")
        .padding(.trailing, AgentBubbleStyle.assistantTrailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sliced: some View {
        content
            .padding(.top, bubble.first ? AgentBubbleStyle.paddingV : bubble.gap)
            .padding(.bottom, bubble.last ? AgentBubbleStyle.paddingV : 0)
            .padding(.horizontal, AgentBubbleStyle.paddingH)
            .frame(maxWidth: bubble.hug ? nil : .infinity, alignment: .leading)
            .background(AgentBubbleStyle.assistantFill, in: AgentBubbleStyle.shape(top: bubble.first, bottom: bubble.last))
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

/// 长按多截气泡时的预览：整段正文画成一个完整气泡
private struct AgentAnswerBubblePreview: View {
    let text: String
    let width: CGFloat

    var body: some View {
        AgentMarkdownBlocks(blocks: AgentMarkdownParser.parse(text), size: AgentTranscriptLayout.textSize)
            .padding(.horizontal, AgentBubbleStyle.paddingH)
            .padding(.vertical, AgentBubbleStyle.paddingV)
            .frame(width: width > 0 ? width : nil)
            .background(AgentBubbleStyle.assistantFill)
    }
}

/// 「正在输入」的三点气泡：本轮进行中、正文没在流式输出时代替原来的进度环 + 秒数（2026-10-12 用户要求）。
/// 三个点依次亮起、微微上浮，形成从左到右的波（iMessage 同款节奏）
struct AgentTypingBubble: View {
    /// 一个波的周期与相邻两点的相位差（秒）
    private static let period = 1.2
    private static let stagger = 0.18

    var body: some View {
        // 30 帧足够画出 1.2 秒一周的小幅波动；默认逐帧会让 ProMotion 屏在思考、调工具的几分钟里一直按 120Hz 重绘
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = Self.wave(t - Double(i) * Self.stagger)
                    Circle()
                        .fill(Theme.text.opacity(0.28 + 0.42 * wave))
                        .frame(width: 8, height: 8)
                        .offset(y: -2.5 * wave)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AgentBubbleStyle.assistantFill, in: .capsule)
        // 圆点没有可读内容，用一段文字代表整个气泡，旁白读「正在输入」
        .accessibilityRepresentation { Text("正在输入") }
        .accessibilityIdentifier("agent-turn-running")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 0…1：每个周期前半段亮起再落下，后半段静止
    private static func wave(_ t: Double) -> Double {
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        let p = phase < 0 ? phase + 1 : phase
        return p < 0.5 ? sin(p * 2 * .pi) : 0
    }
}

// MARK: - 用户气泡

/// 用户提问气泡：操作走 iPhone 原生长按菜单（复制 / 改写重问），不做点按浮现、也不在气泡下方常驻按钮（2026-10-12 用户要求）。
/// `/skill:名字` 渲染成技能 chip，正文只留用户自己的话（复制与改写仍用完整 token 原文）。
struct AgentUserBubble: View {
    let text: String
    let images: [AgentTurnImage]
    let sessionId: String
    let knownSkills: Set<String>?
    let onEdit: (() -> Void)?

    @Environment(\.api) private var api
    @State private var lightbox: DiscoverLightboxContent?

    var body: some View {
        let parsed = AgentSkillText.parseTokens(text, allow: knownSkills)
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            bubble(parsed)
                .contentShape(.contextMenuPreview, AgentBubbleStyle.shape())
                .contextMenu {
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                    if let onEdit {
                        Button("改写这条提问", systemImage: "pencil", action: onEdit)
                    }
                }
        }
        .fullScreenCover(item: $lightbox) { content in
            DiscoverLightbox(content: content).sheetFeedback()
        }
    }

    private func bubble(_ parsed: (names: [String], text: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !parsed.names.isEmpty {
                AgentFlowLayout(spacing: 6) {
                    ForEach(parsed.names, id: \.self) { name in
                        Text("⚡ \(name)")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.white.opacity(0.18), in: .rect(cornerRadius: 8))
                    }
                }
            }
            if !images.isEmpty {
                AgentFlowLayout(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.attachmentId) { index, image in
                        Button {
                            lightbox = DiscoverLightboxContent(
                                urls: images.map { api.agentAttachmentURL(sessionId: sessionId, attachmentId: $0.attachmentId) },
                                initialIndex: index,
                                title: image.name ?? "图片"
                            )
                        } label: {
                            AgentAttachmentThumb(image: image, url: api.agentAttachmentURL(sessionId: sessionId, attachmentId: image.attachmentId))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("放大预览：\(image.name ?? "图片")")
                    }
                }
            }
            if !parsed.text.isEmpty {
                Text(parsed.text)
                    .font(.system(size: AgentTranscriptLayout.textSize))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AgentBubbleStyle.paddingH)
        .padding(.vertical, AgentBubbleStyle.paddingV)
        .background(AgentBubbleStyle.userFill, in: AgentBubbleStyle.shape())
        .contentShape(AgentBubbleStyle.shape())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-user-bubble")
    }
}

/// 气泡里的图片缩略图（按原比例，最高 160、最宽 200，同 Web max-h-40 max-w-[200px]）：
/// 刚发出的用本地预览，回放走会话附件下载接口
struct AgentAttachmentThumb: View {
    let image: AgentTurnImage
    let url: URL

    var body: some View {
        Group {
            if let local = AgentImagePreviews.images[image.attachmentId] {
                Image(uiImage: local).resizable().scaledToFit()
            } else {
                LazyImage(url: url) { state in
                    if let loaded = state.image {
                        loaded.resizable().scaledToFit()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            if state.error != nil {
                                Image(systemName: "photo").foregroundStyle(Theme.textFaint)
                            }
                        }
                        .frame(width: 120, height: 120)
                    }
                }
            }
        }
        .frame(maxWidth: 200, maxHeight: 160)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1)))
    }
}

// MARK: - 处理过程

/// 处理过程胶囊：进行中显示实时状态、完成后显示一句话总结，夹在气泡之间但不抢眼；
/// 点击在下方展开思考与工具调用的混合列表（按实际发生顺序）。
/// 生成式 UI 的绘制调用不算处理过程（它的产出就是紧随其后的卡片），整块只剩它时连折叠头也不出。
struct AgentProcessBlock: View {
    let items: [AgentProcessItem]
    let active: Bool
    @State private var open = false

    /// 折叠块里要列的条目（去掉生成式 UI 的绘制调用）；为空则整块不出现，消息列拆行时据此不给它占行
    static func visibleItems(_ items: [AgentProcessItem]) -> [AgentProcessItem] {
        items.filter { item in
            if case let .tool(tool) = item { return !AgentMediaCards.isMediaCardsTool(tool.name) }
            return true
        }
    }

    var body: some View {
        let visible = Self.visibleItems(items)
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text(active ? AgentTimeline.processStatus(visible) : AgentTimeline.processSummary(visible))
                            .font(.system(size: 13, weight: .medium))
                            .modifier(AgentPulse(active: active))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white.opacity(0.07), in: .capsule)
                    .expandedHitArea(vertical: 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-process-toggle")

                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(visible.indices, id: \.self) { i in
                            switch visible[i] {
                            case let .thinking(text):
                                Text(text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textFaint)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            case let .tool(tool):
                                AgentToolRow(tool: tool)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                }
            }
        }
    }
}

/// 单次工具调用：默认只占一行（工具名 + 参数摘要 + ✓/✗/进度环），点击展开参数（高亮）与输出。
/// 参数生成中时右锚定显示最新生成的尾部——长参数溢出时新字符持续从右侧推入，肉眼可见仍在进行。
struct AgentToolRow: View {
    let tool: AgentToolCall
    @State private var open = false

    static let nameColor = Color(red: 0x9F / 255, green: 0xC6 / 255, blue: 0xE8 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textFaint)
                    Text(tool.name).foregroundStyle(Self.nameColor).layoutPriority(1)
                    if tool.streaming {
                        Text(String(tool.label.dropFirst(tool.name.count + 1).suffix(300)))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text(tool.summary)
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if tool.streaming || tool.output == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(tool.isError ? "✗" : "✓").foregroundStyle(tool.isError ? Theme.danger : Theme.textFaint)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.vertical, 2)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(tool.streaming)
            .accessibilityIdentifier("agent-tool-row")

            if open, !tool.streaming {
                VStack(alignment: .leading, spacing: 6) {
                    if let input = tool.inputDetail {
                        AgentCodeText(code: input.code, language: input.lang, size: 13)
                    }
                    if let output = tool.output {
                        ScrollView {
                            Text(output)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(tool.isError ? Theme.danger : Theme.textMuted)
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 176)
                        .fixedSize(horizontal: false, vertical: output.count < 400)
                    } else {
                        Text("执行中…").font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.02), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.05)))
            }
        }
    }
}

// MARK: - 压缩 / 来源 / 页脚

/// 上下文压缩分隔卡片：横线分隔 + 居中标签，点击展开交接摘要。
/// 它同时是「多次压缩会降低准确性」的可见信号——卡片越多，会话越该另起。
struct AgentCompactionCard: View {
    let summary: String
    let tokensBefore: Int?
    let tokensAfter: Int?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text(label).fixedSize()
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textFaint)
                .expandedHitArea(vertical: 12)
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary).font(.system(size: 14)).foregroundStyle(Theme.textFaint).textSelection(.enabled)
                    Text("此前的对话已由交接摘要替代。多次压缩可能降低模型准确性，建议适时开启新会话。")
                        .font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 2) }
            }
        }
    }

    private var label: String {
        if let tokensBefore, let tokensAfter { return "已压缩上下文（\(tokensBefore) → \(tokensAfter) tokens）" }
        return "已压缩上下文"
    }
}

/// 派生会话的来源卡片：只展示来源关系，不把旧消息重复画成当前会话里可重试的轮次
struct AgentHandoffCard: View {
    let sourceId: String
    let sourceTitle: String?
    @Environment(Router.self) private var router

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("已从「\(sourceTitle?.isEmpty == false ? sourceTitle! : "会话 \(sourceId.prefix(8))")」续接上下文")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("这是一个独立的新会话；后续操作不会改写原会话。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
            Button {
                router.push(.session(id: sourceId))
            } label: {
                HStack(spacing: 2) {
                    Text("查看原会话")
                    Image(systemName: "chevron.right").font(.system(size: 11))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .expandedHitArea(vertical: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.white.opacity(0.025), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
        .accessibilityIdentifier("agent-handoff")
    }
}

/// 一轮异常收尾时的小字：已停止 / 已中断。正常跑完不出任何东西（耗时 2026-10-12 用户要求去掉）；
/// 进行中不走这里（是三点气泡，见 AgentTypingBubble）；复制走气泡的长按菜单
struct AgentTurnFooter: View {
    let turn: AgentTurn

    /// 页脚会不会画出东西；消息列拆行时据此决定要不要给它占一行
    static func hasContent(_ turn: AgentTurn) -> Bool {
        turn.status == .done && (turn.stopped || turn.interrupted)
    }

    var body: some View {
        Group {
            if turn.stopped {
                Text("已停止").accessibilityIdentifier("agent-turn-stopped")
            } else if turn.interrupted {
                Text("已中断").accessibilityIdentifier("agent-turn-interrupted")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textFaint)
        .padding(.leading, 6)
    }
}

/// 流式光标：正文尾部的呼吸圆点
struct AgentStreamingCursor: View {
    var body: some View {
        Circle().fill(Theme.textMuted).frame(width: 9, height: 9)
            .modifier(AgentPulse(active: true))
    }
}

/// 进行中文案的呼吸效果。用 PhaseAnimator 循环：原先 onAppear 里起一个 repeatForever，懒加载行滚出再滚回时
/// 状态已是「暗」、再赋值不算变化，动画不会重新开始
struct AgentPulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, dim in
                view.opacity(dim ? 0.45 : 1)
            } animation: { _ in .easeInOut(duration: 0.9) }
        } else {
            content
        }
    }
}

/// 简单的流式换行布局（技能 chip、图片缩略图）
struct AgentFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
