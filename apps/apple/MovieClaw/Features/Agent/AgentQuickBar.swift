import SwiftUI

/// 「我的」页的 AI 一行输入框（2026-10-12 用户按 Muse 的底栏输入框要求）：加号 · 输入框 · 发送；
/// 没有语音输入；模型 / 思维链不占地方，用新会话页记住的上次选择（AgentComposerPrefs）。发送 = 新建会话并进入。
///
/// 要两样系统各给一半的东西：
/// - 下滑时跟标签栏一起缩进那一行——只有标签栏附件（tabViewBottomAccessory）有，自定义视图读不到标签栏收没收起；
/// - 打字时跟着键盘上下——附件不跟键盘走（键盘会把它整条盖住）。
/// 所以平时是附件（AgentQuickBar，入口），点它附件让位、页面底部同一位置换上同款玻璃的真输入框（AgentQuickInput），
/// 跟着键盘上去；收键盘时一起落回原位，**等键盘完全收起**再原地换回附件。任何时刻屏幕上只有一个输入框
/// （试过附件常驻 + 键盘上方另浮一条，收键盘时两条同时出现、还慢半拍，用户真机反馈不顺）。
@Observable
@MainActor
final class AgentQuickDraft {
    /// 草稿在入口和真输入框之间共用：收起键盘打了一半的字、选的图片技能都留着
    var draft = AgentDraft()
    /// 正在打字：附件让位，页面底部是真输入框
    var editing = false
    /// 真输入框一出来就弹加号菜单（从附件上的加号点进来）
    var opensPlusMenu = false
    var sending = false
    var askingConsent = false
    var consentProviders: [String] = []

    var canSend: Bool { !draft.isEmpty && !sending }

    func open(plusMenu: Bool = false) {
        opensPlusMenu = plusMenu
        editing = true
    }

    /// 第一次发给 AI 前先说明去向、取得同意（AgentAIConsent），同新会话页
    func submit(api: APIClient, router: Router, feedback: Feedback) {
        guard canSend else { return }
        guard AgentAIConsent.granted else {
            Task {
                consentProviders = AgentAIConsent.providers(await AgentCatalog.modelOptions(api: api))
                askingConsent = true
            }
            return
        }
        send(api: api, router: router, feedback: feedback)
    }

    func send(api: APIClient, router: Router, feedback: Feedback) {
        let message = draft.message
        let images = draft.images.map { AgentTurnImage(attachmentId: $0.attachmentId, name: $0.name) }
        sending = true
        Task {
            defer { sending = false }
            do {
                let choice = AgentComposerPrefs.load().reconciled(with: await AgentCatalog.modelOptions(api: api))
                let id = try await AgentConversationRegistry.start(
                    api: api, input: message, images: images, thinking: choice.thinking, model: choice.model
                )
                draft.clear()
                editing = false
                router.push(.session(id: id))
            } catch {
                feedback.error(error)
            }
        }
    }
}

/// 标签栏附件里的入口：长得像一行输入框，点哪儿都是换上真输入框（加号顺带弹加号菜单）
struct AgentQuickBar: View {
    let quick: AgentQuickDraft

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    /// 入口上显示的草稿摘要：文字优先，只有图片 / 技能时说一声
    private var summary: String? {
        let draft = quick.draft
        if !draft.text.isEmpty { return draft.text }
        if !draft.images.isEmpty { return "已添加 \(draft.images.count) 张图片" }
        if !draft.skills.isEmpty { return draft.skills.map { "⚡ \($0)" }.joined(separator: " ") }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                quick.open(plusMenu: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19))
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加图片或技能")
            .accessibilityIdentifier("agent-quick-entry-plus")

            Button {
                quick.open()
            } label: {
                Text(summary ?? "给 AI 助手发消息")
                    .font(.system(size: 17))
                    .foregroundStyle(summary == nil ? Theme.textFaint : Theme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-quick-entry")

            // 收进标签栏那一行（inline）时地方小，没内容就不出发送键
            if placement != .inline || quick.canSend {
                Button {
                    quick.submit(api: api, router: router, feedback: feedback)
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(AgentBubbleStyle.userFill, in: .circle)
                        .expandedHitArea(horizontal: 4, vertical: 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
                .opacity(quick.canSend ? 1 : 0.45)
                .disabled(!quick.canSend)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("agent-quick-entry-send")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
    }
}

/// 打字时接替附件的真输入框：放在「我的」页底部的安全区里（附件让位后这里就是附件原来的位置），跟着键盘上下
struct AgentQuickInput: View {
    let quick: AgentQuickDraft

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    var body: some View {
        @Bindable var quick = quick
        AgentComposer(
            draft: $quick.draft,
            placeholder: "给 AI 助手发消息",
            busy: quick.sending,
            autoFocus: true,
            compact: true,
            opensPlusMenu: quick.opensPlusMenu,
            onIdle: { quick.editing = false },
            onSubmit: { quick.submit(api: api, router: router, feedback: feedback) }
        )
        .padding(.horizontal, AgentQuickInput.sideInset)
        .padding(.bottom, AgentQuickInput.bottomGap)
    }

    /// 与系统附件对齐的边距（模拟器量的，见 AgentUITests.testQuickBarHandoffKeepsOneInput）
    static let sideInset: CGFloat = 21
    static let bottomGap: CGFloat = 8
}

/// 首次发送前的同意说明：挂在常驻的标签栏层上（附件上的发送键不经真输入框也能发）
struct AgentQuickConsentModifier: ViewModifier {
    let quick: AgentQuickDraft?

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { quick?.askingConsent ?? false }, set: { quick?.askingConsent = $0 })) {
            if let quick {
                AgentAIConsentSheet(providers: quick.consentProviders) {
                    quick.send(api: api, router: router, feedback: feedback)
                }
            }
        }
    }
}
